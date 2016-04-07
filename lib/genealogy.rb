$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../lib")
require "genealogy/version"
require 'ansel'
require 'net/ldap'
require 'set'

$names = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new}}
$places = {}

def compareindividuals *individuals
  puts "Comparing #{individuals.map{|i| i}.join ', '}"
  
end

def listeventsbyplace(places: $places, depth: 0)
  if depth == 0
    puts "Listing events by place"
  end
  places.keys.sort.each do |key|
    puts "#{' ' * depth}#{places[key].rawname}"
    places[key].events.each do |event|
      puts "#{' ' * depth} #{event.inspect}"
    end
    listeventsbyplace places: places[key].places, depth: depth+1
  end
end

class User
  attr_reader :ldap
  attr_reader :dn
  attr_reader :objectfromdn
  attr_reader :attributemetadata

  def initialize(username: username, password: password)
    @base = 'dc=deepeddy,dc=com'
    @dn = "cn=#{username},#{@base}"
    @ldap = Net::LDAP.new(
      host: '192.168.99.100',
      port: 389,
      auth: {method: :simple,
             username: @dn,
             password: password,
            })
    if rootdse = @ldap.search_subschema_entry
      @attributemetadata = Hash.new {|hash, key| hash[key] = {}}
      rootdse.attributetypes.each do |attrtype|
        if matchdata = /\(\s*(?<oid>[\d\.]+)\s*(?<args>.*\s*)\)/.match(attrtype)
          oid = matchdata[:oid]
          tmphash = {}
          argarray = matchdata[:args].split(/\s+/)
          thisarg = []
          until argarray == [] do
            arg = argarray.pop
            if /[^A-Z-]/.match arg
              thisarg.unshift arg
            else
              text = thisarg.join(' ')
              if matchdata = text.match(/^'(?<text>.*)'$/)
                tmphash[arg.downcase.to_sym] = matchdata[:text]
              else
                tmphash[arg.downcase.to_sym] = text
              end
              thisarg = []
            end
          end
          tmphash[:oid] = oid
          name = tmphash.delete :name
          name = name.downcase.to_sym
          @attributemetadata[name] = tmphash
        end
      end
    else
      raise "Couldn't read root subschema record: #{@ldap.get_operation_result.message}"
    end


    @objectfromdn = Hash.new { |hash, key| hash[key] = getobjectfromdn key}
  end

  def classfromentry(entry)
    objectclasses = entry.objectclass.map {|klass| klass.downcase.to_sym}
    ldapclass = objectclasses.detect do |ldapclass|
      GedcomEntry.getclassfromldapclass ldapclass
    end
    GedcomEntry.getclassfromldapclass ldapclass
  end

  def getobjectfromdn(dn)
    object = nil
    unless @ldap.search(
      base: dn,
      scope: Net::LDAP::SearchScope_BaseObject,
      return_result: false,
    ) do |entry|
        object = classfromentry(entry).new ldapentry: entry, user: self
      end
      raise "Couldn't find #{dn}: #{@ldap.get_operation_result.message}"
    end
    object
  end

  def openldap
    @ldap.open do
      yield
    end
  end
  
  def modifyattributes(dn, ops)
    unless @ldap.modify dn: dn, operations: ops
      raise "Couldn't modify attributes #{ops} for #{dn}: #{@ldap.get_operation_result.message}"
    end
  end
  
  def sources
    unless @sources
      @sources = []
      unless @ldap.search(
        base: @dn,
        scope: Net::LDAP::SearchScope_SingleLevel,
        filter: Net::LDAP::Filter.eq("objectclass", "gedcomSource"),
        return_result: false,
      ) do |entry|
          source = classfromentry(entry).new ldapentry: entry, user: self
          @objectfromdn[source.dn] = source
          @sources.push source
        end
        raise "Couldn't search #{@dn} for sources: #{@ldap.get_operation_result.message}"
      end
    end
    @sources
  end

  def findname(first: '', last: '')
    firstinit = first[0]
    if firstinit == first
      dn = "givenName=#{first},sn=#{last},#{@dn}"
    else
      dn = "givenName=#{first},givenname=#{firstinit},sn=#{last},#{@dn}"
    end
    unless @ldap.search(
      base: dn,
      filter: Net::LDAP::Filter.eq("objectclass", "gedcomIndividual"),
      deref: Net::LDAP::DerefAliases_Search,
      return_result: false,
    ) do |entry|
        indi = classfromentry(entry).new ldapentry: entry, user: self
        @objectfromdn[indi.dn] = indi
        puts indi
      end
      raise "Couldn't search #{@dn} for names: #{@ldap.get_operation_result.message}"
    end
  end
end

class LdapAlias
  attr_reader :dn

  def initialize(dn, user)
    @dn = dn
    @user = user
  end

  def object
    @user.objectfromdn[dn]
  end

  def inspect
    "#<LdapAlias #{dn}>"
  end

  def method_missing(m, *args, &block)  
    object.send m, *args, &block
  end  

  def respond_to?(method)
    super || object.respond_to?(method)
  end
end

class GedcomEntry
  attr_reader :fieldname
  attr_reader :label
  attr_reader :arg
  attr_accessor :parent
  attr_reader :baddata
  attr_accessor :dn

  @@multivaluevariables = Hash.new { |hash, key| hash[key] = Set.new}
  @@gedcomtofield = Hash.new { |hash, key| hash[key] = Hash.new}
  @@fieldtoldap = Hash.new { |hash, key| hash[key] = Hash.new}
  @@ldaptofield = Hash.new { |hash, key| hash[key] = Hash.new}
  @@classtoldapclass = Hash.new
  @@ldapclasstoclass = Hash.new

  def self.attr_multi(fieldname)
    @@multivaluevariables[self].add fieldname
  end

  def self.attr_gedcom(fieldname, gedcomname)
    @@gedcomtofield[self][gedcomname] = fieldname
  end
  
  def self.attr_ldap(fieldname, ldapname)
    @@fieldtoldap[self][fieldname] = ldapname
    @@ldaptofield[self][ldapname] = fieldname
  end

  def self.ldap_class(ldapclass)
    @@classtoldapclass[self] = ldapclass
    @@ldapclasstoclass[ldapclass] = self
  end

  def self.getclassfromldapclass(ldapclass)
    @@ldapclasstoclass[ldapclass]
  end

  def initialize(ldapentry: nil, **options)
    options.each do |fieldname, value|
      if value
        fieldname = @@ldaptofield[self.class][fieldname] || @@ldaptofield[self.class.superclass][fieldname] || fieldname
        if @@multivaluevariables[self.class].include?(fieldname) || @@multivaluevariables[self.class.superclass].include?(fieldname)
          instance_variable_set "@#{fieldname}".to_sym, [value]
        else
          instance_variable_set "@#{fieldname}".to_sym, value
        end
      end
    end
    if @label
      @source.labels[@label] = self
      @source.references[@label].each do |ref|
        ref.parent.delfields(ref.fieldname => ref)
        ref.parent.addfields(ref.fieldname => self)
      end
    end
    if ldapentry
      ldapentry.each do |fieldname, value|
        syntax = @user.attributemetadata[fieldname][:syntax]
        if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
          value.map! {|dn| LdapAlias.new dn, @user}
        end
        fieldname = @@ldaptofield[self.class][fieldname] || @@ldaptofield[self.class.superclass][fieldname] || fieldname
        if @@multivaluevariables[self.class].include?(fieldname) || @@multivaluevariables[self.class.superclass].include?(fieldname)
          instance_variable_set "@#{fieldname}".to_sym, value
        else
          instance_variable_set "@#{fieldname}".to_sym, value[0]
        end
      end
    else
      if @user
        if @@classtoldapclass[self.class] || @@classtoldapclass[self.class.superclass]
          addtoldap
        end
      end
    end
    if @parent
      @parent.addfields(fieldname => self)
    end
  end

  def to_s
    "#{@label} #{@fieldname} #{arg}"
  end

  def ldapfields
    @@fieldtoldap[self.class].keys + @@fieldtoldap[self.class.superclass].keys
  end

  def rdn
    if @label
      uid = @label.to_s
      @noldapobject = false
    elsif @title
      uid = @title
      @noldapobject = false
    else
      puts "Don't have a UID yet for #{self.inspect}"
      #puts parentdn.inspect
      @noldapobject = true
    end
    [:uniqueidentifier, uid]
  end
  
  def addtoldap
    if @parent
      parentdn = @parent.dn
    elsif @source
      parentdn = @source.dn
    else
      parentdn = @user.dn
    end
    
    (rdnfield, rdnvalue) = self.rdn
    unless @noldapobject
      @dn = "#{rdnfield}=#{rdnvalue},#{parentdn}"
      @user.objectfromdn[@dn] = self
      attrs = {}
      attrs[:objectclass] = ["top", @@classtoldapclass[self.class].to_s]
      attrs[rdnfield] = rdnvalue
      if ldapsuperclass = @@classtoldapclass[self.class.superclass]
        attrs[:objectclass].push ldapsuperclass.to_s
      end
      ldapfields.each do |fieldname|
        ldapfieldname = @@fieldtoldap[self.class][fieldname] || @@fieldtoldap[self.class.superclass][fieldname] || fieldname
        if value = instance_variable_get("@#{fieldname}".to_sym)
          unless value == [] or value == ""
            if value.kind_of? GedcomEntry
              if value.dn
                attrs[ldapfieldname] = value.dn
            end
            else
              attrs[ldapfieldname] = value
            end
          end
        end
      end
      unless @user.ldap.add dn: @dn, attributes: attrs
        raise "Couldn't add #{self.inspect} at #{@dn} with attributes #{attrs.inspect}: #{@user.ldap.get_operation_result.message}"
      end
    end
  end

  def inspect
    if @baddata
      "#<#{self.class}: #{to_s} :BAD>"
    else
      "#<#{self.class}: #{to_s}>"
    end
  end
  
  def addfields(**options)
    ops = []
    options.each do |fieldname, value|
      fieldname = @@gedcomtofield[self.class][fieldname] || @@gedcomtofield[self.class.superclass][fieldname] || fieldname
      if @@multivaluevariables[self.class].include?(fieldname) || @@multivaluevariables[self.class.superclass].include?(fieldname)
        if oldvalues = instance_variable_get("@#{fieldname}".to_sym)
          instance_variable_set "@#{fieldname}".to_sym, oldvalues + [value]
        else
          instance_variable_set "@#{fieldname}".to_sym, [value]
        end
      else
        instance_variable_set "@#{fieldname}".to_sym, value
      end
      if @user and @dn
        if fieldname = (@@fieldtoldap[self.class][fieldname] || @@fieldtoldap[self.class.superclass][fieldname])
          if @noldapobject
            (rdnfield, rdnvalue) = self.rdn
            if rdnfield == fieldname
              # We weren't in LDAP, but now we can be added
              puts "delayed addition of #{@dn} to ldap"
              self.addtoldap
            end
          else
            if value.kind_of? GedcomEntry
              if value.dn
                ops.push [:add, fieldname, value.dn]
              end
            else
              ops.push [:add, fieldname, value]
            end
          end
        end
      end
    end
    unless ops == []
      @user.modifyattributes @dn, ops
    end
  end
  
  def delfields(**options)
    options.each do |fieldname, value|
      if @@multivaluevariables[self.class].include?(fieldname) || @@multivaluevariables[self.class.superclass].include?(fieldname)
        if oldvalues = instance_variable_get("@#{fieldname}".to_sym)
          instance_variable_set "@#{fieldname}".to_sym, oldvalues.delete_if {|i| i == value}
        end
      else
        instance_variable_set "@#{fieldname}".to_sym, nil
      end
    end
  end
  
  def self.definedfieldnames
    ObjectSpace.each_object(Class).select { |klass| klass < self }.map {|i| "#{i.to_s[6,999].downcase}".to_sym}
  end
end

class GedcomHead < GedcomEntry
  attr_reader :source
  attr_reader :destination
  attr_reader :date
  attr_reader :subm
  attr_reader :file
  attr_reader :gedcom
  attr_reader :charset

  def initialize(source: nil, **options)
    if source
      super(source: source, parent: source, **options)
    else
      super(**options)
    end
  end
  
  def dn
    @parent.dn
  end
end

class GedcomGedc < GedcomEntry
  attr_reader :version
  attr_reader :form
end

class GedcomSubm < GedcomEntry
  attr_reader :name
  attr_reader :address
  attr_multi :name
end

class GedcomAddr < GedcomEntry
  attr_reader :address
  attr_reader :phones
  attr_multi :phon
  attr_gedcom :address, :addr

  def initialize(arg: "", **options)
    @phones = []
    super(address: arg, **options)
  end
  
  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :cont
        @address += "\n" + value
        options.delete fieldname
      end
    end
    super(**options)
  end
end

class GedcomString < GedcomEntry
  def initialize(fieldname: "", arg: "", parent: nil, **options)
    parent.addfields(fieldname => arg)
  end
end

class GedcomCorp < GedcomString
end

class GedcomCaus < GedcomString
end

class GedcomAuth < GedcomString
end

class GedcomPubl < GedcomString
end

class GedcomPhon < GedcomString
end

class GedcomVers < GedcomString
end

class GedcomForm < GedcomString
end

class GedcomFile < GedcomString
end

class GedcomDate < GedcomEntry
  attr_reader :relative
  attr_reader :year
  attr_reader :month
  attr_reader :day
  attr_reader :raw
  attr_reader :events

  Monthmap = {
    NIL => 0,
    "JAN" => 1,
    "FEB" => 2,
    "MAR" => 3,
    "APR" => 4,
    "MAY" => 5,
    "JUN" => 6,
    "JUL" => 7,
    "AUG" => 8,
    "SEP" => 9,
    "OCT" => 10,
    "NOV" => 11,
    "DEC" => 12,
  }
  
  def initialize(arg: "", parent: nil, **options)
    #puts "#{self.class} #{arg.inspect}"
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    raw = arg
    args = arg.split(/\s+/)
    relative = 0
    if args[0] == 'AFT'
      relative = +10
      args.shift
    elsif args[0] == 'BEF'
      relative = -10
      args.shift
    elsif args[0] == 'ABT'
      relative = +1
      args.shift
    elsif args[0] == 'BET'
      relative = +2
      args.shift
      args = args[0..(args.index("AND")-1)]
    end
    baddata = false
    year = args.pop
    if (year =~ /[^\d]/)
      baddata = true
      year = Integer(year[/^\d+/]||0)
    else
      year = Integer(year)
    end
    if month = args.pop
      unless month = Monthmap[month]
        baddata = true
        month = 0
      end
    else
      month = 0
    end
    day = args.pop
    day = Integer(day || 0)
    
    parent.addfields(date: raw,
                     # Don't know why these need to be coerced to strings to be accepted by openldap
                     year: year.to_s,
                     month: month.to_s,
                     day: day.to_s,
                     relativetodate: relative.to_s,
                     baddata: baddata.to_s.upcase)
  end
end

class GedcomPlac < GedcomEntry
  attr_reader :name
  attr_reader :rawname
  attr_reader :places
  attr_reader :events

  # This code is less that completely obvious.
  #
  # Note 1: If this is called by the internal recursion, it has a child: argument, but if it's called by the gedcom parsing code,
  # it has a parent: argument.
  #
  # Note 2: This is because internal recursion is creating a tree in the opposite direction from the gedcom parsing code.
  #
  # Note 3: We do not care what GedcomPlac.new actually returns. The reason for this is that the place may already exist and we
  # want to return the pre-existing place, not generate a new one. So we put either outselves or the pre-existing place in the 'place' variable.
  #
  # Note 4: So....if we have a parent argument, we attach 'place' to that argument as a child.
  #
  # Note 5: Conversely, if we have a child argument, we attach 'place' to that argument as it's parent.
  #
  # Clear as mud?
  def initialize(fieldname: nil, label: nil, arg: "", parent: nil, child: nil, source: nil, **options)
    #puts "#{self.class} #{arg.inspect} #{child.inspect}"
    @places = {}
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    (@rawname, parentname) = arg.split(/\s*,\s*/,2)
    @name = @rawname.upcase.gsub(/[^A-Z0-9]+/, '').to_sym
    if parentname
      GedcomPlac.new arg: parentname, child: self, source: source
      # We may have already existed, so reach down our own throat. This may just return ourself.
      place = self.parent.places[@name]
    else
      # Root of the place tree.
      unless $places[@name]
        $places[@name] = self
      end
      place = $places[@name]
    end
    if child
      unless place and place.places[child.name]
        place.addplace child
      end
      child.parent = place
    end
    if label
      place.label = label
    end
    if parent
      place.addevent parent
      parent.addfields(fieldname => place)
    end
  end
  
  def addplace(place)
    @places[place.name] = place
  end
  
  def addevent(event, date = event.date)
    if date
      @events[@year][@month][@day][@relativetodate].push event
    else
      @events[999999][0][0][0].push event
    end
  end

  def delevent(event, date)
    if date
      @events[@year][@month][@day][@relativetodate].delete_if {|i| i == event}
    else
      @events[999999][0][0][0].delete_if {|i| i == event}
    end
  end

  def to_s
    if parent
      "#{@rawname}, #{parent}"
    else
      "#{@rawname}"
    end
  end
end

class GedcomEven < GedcomEntry
  ldap_class :gedcomevent
  attr_reader :date
  attr_ldap :date, :gedcomdate
  attr_ldap :year, :year
  attr_ldap :month, :month
  attr_ldap :day, :day
  attr_ldap :relativetodate, :relativetodate
  attr_ldap :baddata, :baddata
  attr_gedcom :place, :plac
  attr_ldap :place, :gedcom
  attr_reader :description
  attr_gedcom :description, :type
  attr_ldap :description, :description
  attr_reader :sources
  attr_ldap :sources, :sourcedns

  def initialize(source: nil, **options)
    super(**options)
    @sources = []
    if source
      addsource source
    end
  end
  
  def to_s
    if @description
      "#{@date} #{@description} #{@place.inspect}"
    else
      "#{@date} #{@place.inspect}"
    end
  end

  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :sour
        addsource value
        options.delete fieldname
      end
    end
    super(**options)
  end

  def addsource(source)
    addfields(:sources => source)
  end

  def delsource(source)
    delfields(sources: source)
  end

  def rdn
    if @description
      description = @description.gsub(/[,"]/, '')
      @noldapobject = false
    else
      @noldapobject = true
    end
    [:description, description]
  end
end

class GedcomBirt < GedcomEven
  ldap_class :gedcombirth
  attr_reader :individual
  attr_ldap :individual, :individualdn

  def initialize(parent: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(individual: parent, parent: parent, description: "Birth of #{parent.fullname.gsub(/[,"]/, '')}", **options)
    end
  end

  def to_s
    if date
      "#{@description} #{date} #{@place}"
    else
      "#{@description} #{@place}"
    end
  end
end

class GedcomDeat < GedcomEven
  attr_reader :individual
  attr_gedcom :cause, :caus

  def initialize(parent: nil, **options)
    super(individual: parent, **options)
  end

  def to_s
    if date
      "#{@individual.names[0]} #{date} #{@place}"
    else
      "#{@individual.names[0]} ? #{@place}"
    end
  end
end

class GedcomBuri < GedcomEven
  attr_reader :individual

  def initialize(parent: nil, **options)
    super(individual: parent, **options)
  end

  def to_s
    if @individual
      name = @individual.names[0]
    else
      name = ""
    end
    if @date
      "#{name} #{@date} #{@place}"
    else
      "#{name} #{@place}"
    end
  end
end

class GedcomMarr < GedcomEven
  attr_gedcom :officiator, :offi

  def to_s
    "#{date} #{@parent.inspect}"
  end
end

class GedcomDiv < GedcomEven
  def to_s
    "#{date} #{@parent.inspect}"
  end
end

class GedcomAdop < GedcomEven
  attr_reader :individual
  attr_reader :parents

  def initialize(parent: nil, **options)
    @parents = []
    super(individual: parent, **options)
  end

  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :famc
        if value.respond_to? :addevent
          value.addevent self, @date
          if value.husband
            @parents.push value.husband
          end
          if value.wife
            @parents.push value.wife
          end
        end
        options.delete fieldname
      end
    end
    super(**options)
  end

  def delfields(**options)
    options.each do |fieldname, value|
      if fieldname == :famc
        if value.respond_to? :delevent
          value.delevent self, @date
          if value.husband
            @parents.delete_if {|i| i == value.husband}
          end
          if value.wife
            @parents.delete_if {|i| i == value.wife}
          end
        end
      else
        super
      end
    end
  end

  def to_s
    @individual.to_s
  end
end

class GedcomBapm < GedcomEven
end

class GedcomIndi < GedcomEntry
  ldap_class :gedcomindividual
  attr_reader :gender, :sex
  attr_reader :birth
  attr_gedcom :birth, :birt
  attr_ldap :birth, :birthdn
  attr_reader :baptism
  attr_gedcom :death, :deat
  attr_accessor :mother
  attr_accessor :father
  attr_multi :events
  attr_reader :names
  attr_multi :names
  attr_gedcom :names, :name
  attr_ldap :names, :namedns
  attr_reader :sources
  attr_gedcom :sources, :sour
  attr_ldap :sources, :sourcedns
  attr_multi :sources
  attr_reader :fullname
  attr_ldap :fullname, :cn
  attr_ldap :first, :givenname
  attr_ldap :last, :sn
  attr_ldap :suffix, :initials

  def initialize(source: nil, **options)
    #puts "#{self.class} #{arg.inspect}"
    @names = []
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    super
  end

  def to_s
    if @birth and @birth.respond_to? :date
      birthdate = @birth.date
    else
      birthdate = '?'
    end
    if @death
      if @death.respond_to? :date
        deathdate = @death.date
      else
        deathdate = '?'
      end
    else
      deathdate = ''
    end
    "#{@fullname} #{birthdate} - #{deathdate}"
  end

  def addevent(event, date = event.date)
    if date
      @events[date.year][date.month][date.day][date.relative].push event
    else
      @events[999999][0][0][0].push event
    end
  end

  def delevent(event, date)
    if date
      @events[date.year][date.month][date.day][date.relative].delete_if {|i| i == event}
    else
      @events[999999][0][0][0].delete_if {|i| i == event}
    end
  end

  def showevents
    puts "Events for #{self.inspect}:"
    @events.keys.sort.each do |year|
      @events[year].keys.sort.each do |month|
        @events[year][month].keys.sort.each do |day|
          @events[year][month][day].keys.sort.each do |relative|
            puts "  #{@events[year][month][day][relative].inspect}"
          end
        end
      end
    end
  end
  
  def addsource(source)
    addfields(sources: source)
    @events.keys.each do |year|
      @events[year].keys.each do |month|
        @events[year][month].keys.each do |day|
          @events[year][month][day].keys.each do |relative|
            @events[year][month][day][relative].each do |event|
              event.addsource source
            end
          end
        end
      end
    end
  end

  def delsource(source)
    delfields(sources: source)
    @events.keys.each do |year|
      @events[year].keys.each do |month|
        @events[year][month].keys.each do |day|
          @events[year][month][day].keys.each do |relative|
            @events[year][month][day][relative].each do |event|
              event.delsource source
            end
          end
        end
      end
    end
  end
  
  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :name
        unless @fullname
          # If there are more than one name defined, populate with the first one; the others will be findable via the name objects
          if fullname = value.to_s
            addfields(fullname: fullname)
          end
          if first = value.first
            addfields(first: first)
          end
          if last = value.last
            addfields(last: last)
          end
          if suffix = value.suffix
            addfields(suffix: suffix)
          end
        end
      elsif fieldname == :birt
        addevent value, nil
      elsif fieldname == :deat
        addevent value, nil
      elsif fieldname == :buri
        addevent value, nil
        options.delete fieldname
      elsif fieldname == :bapm
        addevent value, nil
        options.delete fieldname
      elsif fieldname == :even
        addevent value, nil
        options.delete fieldname
      elsif fieldname == :adop
        addevent value, nil
      elsif fieldname == :sour
        addsource value
        options.delete fieldname
      end
    end
    super(**options)
  end
end

class GedcomChar < GedcomEntry
  attr_reader :charset
  
  def initialize(fieldname: nil, arg: "", parent: nil, **options)
    if arg == 'ANSEL'
      parent.addfields(fieldname => ANSEL::Converter.new)
    else
      raise "Don't know what to do with #{arg} encoding"
    end
  end
end

class GedcomOffi < GedcomEntry
  def initialize(arg: "", parent: nil, **options)
    (@first, @last, @suffix) = arg.split(/\s*\/[\s,]*/)
    parent[fieldname] = $names[@last][@first][@suffix]
  end
end

class GedcomName < GedcomEntry
  ldap_class :gedcomname
  attr_reader :first
  attr_reader :last
  attr_reader :suffix
  attr_accessor :dn
  
  def initialize(arg: "", fieldname: fieldname, parent: nil, **options)
    (first, last, suffix) = arg.split(/\s*\/[\s*,]*/)
    $names[last][first][suffix] = self
    super(fieldname: fieldname, parent: parent, first: first, last: last, suffix: suffix, **options)
  end
  
  def addtoldap
    dn=@user.dn
    if @last
      clean = @last.gsub(/[,"]/, '')
      if clean == ''
        clean = 'unknown'
      end
      dn = "sn=#{clean},#{dn}"
      attrs = {
        sn: @last,
        objectclass: ["top", "gedcomName"],
      }
      unless @user.ldap.search(
        base: dn,
        scope: Net::LDAP::SearchScope_BaseObject,
        return_result: false,
      )
        unless @user.ldap.add dn: dn, attributes: attrs
          raise "Couldn't add sn #{@last} at #{dn} with attributes #{attrs.inspect}: #{@user.ldap.get_operation_result.message}"
        end
      end

      if @first
        firstinitial = @first[0]
        
        unless firstinitial == @first
          dn = "givenName=#{firstinitial},#{dn}"
          unless @user.ldap.search(
            base: dn,
            scope: Net::LDAP::SearchScope_BaseObject,
            return_result: false,
          )
            attrs[:givenname] = firstinitial
            unless @user.ldap.add dn: dn, attributes: attrs
              raise "Couldn't add first initial #{firstinitial} at #{dn} with attributes #{attrs.inspect}: #{@user.ldap.get_operation_result.message}"
            end
          end
        end

        clean = @first.gsub(/[,"]/, '')
        if clean == ''
          clean = 'unknown'
        end
        dn = "givenName=#{clean},#{dn}"
        unless @user.ldap.search(
          base: dn,
          scope: Net::LDAP::SearchScope_BaseObject,
          return_result: false,
        )
          attrs[:givenname] = @first
          unless @user.ldap.add dn: dn, attributes: attrs
            raise "Couldn't add givenname #{@first} at #{dn} with attributes #{attrs.inspect}: #{@user.ldap.get_operation_result.message}"
          end
        end
        
        if @suffix
          clean = @suffix.gsub(/[,"]/, '')
          if clean == ''
            clean = 'unknown'
          end
          dn = "initials=#{clean},#{dn}"
          unless @user.ldap.search(
            base: dn,
            scope: Net::LDAP::SearchScope_BaseObject,
            return_result: false,
          )
            attrs[:initials] = @suffix
            unless @user.ldap.add dn: dn, attributes: attrs
              raise "Couldn't add initials #{@suffix} at #{dn} with attributes #{attrs.inspect}: #{@user.ldap.get_operation_result.message}"
            end
          end
        end
      end
      @dn = dn

      uid = parent.label.to_s
      aliasdn = "uniqueidentifier=#{uid},#{dn}"
      attrs = {
        uniqueidentifier: uid,
        objectclass: ["alias", "extensibleObject"],
        aliasedobjectname: parent.dn,
      }
      #puts "Adding alias to #{parent.dn} under #{dn} as #{aliasdn} with attributes: #{attrs.inspect}"
      unless @user.ldap.add dn: aliasdn, attributes: attrs
        raise "Couldn't add alias #{aliasdn} with attributes #{attrs.inspect}: #{@user.ldap.get_operation_result.message}"
      end
      @user.objectfromdn[dn] = self
    end
  end

  def to_s
    if @suffix
      "#{@first} /#{@last}/#{@suffix}"
    else
      "#{@first} /#{@last}/"
    end
  end
end

class GedcomSex < GedcomEntry
  def initialize(fieldname: nil, arg: "", parent: nil, **options)
    if /^m/i.match(arg)
      gender = :male
    elsif /^f/i.match(arg)
      gender = :female
    else
      gender = arg
    end
    parent.addfields(fieldname => gender)
  end
  
  def to_s
    @gender
  end
end

class GedcomType < GedcomString
end

class GedcomSour < GedcomEntry
  ldap_class :gedcomsource
  attr_reader :version
  attr_gedcom :version, :vers
  attr_ldap :version, :version
  attr_reader :title
  attr_gedcom :title, :titl
  attr_ldap :title, :title
  attr_reader :note
  attr_reader :events
  attr_reader :corp
  attr_ldap :corp, :corp
  attr_reader :auth
  attr_ldap :auth, :author
  attr_reader :publ
  attr_ldap :publ, :publication
  attr_reader :filename
  attr_reader :head
  attr_reader :labels
  attr_reader :references
  attr_ldap :rawdata, :rawdata

  def initialize(arg: nil, filename: nil, parent: nil, source: nil, **options)
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    @authors = []
    if filename
      super(filename: filename, title: filename, source: source, rawdata: (File.read filename), **options)
    else
      super(parent: source, source: source, title: arg, **options)
    end
  end
  
  def addhead head
    @head = head
  end
  
  def makeentry(label, fieldname, arg, parent)
    if GedcomEntry.definedfieldnames.member? fieldname
      classname = Module.const_get ("Gedcom" + fieldname.to_s.capitalize)
    else
      classname = GedcomEntry
    end
    if matchdata = /^\@(?<ref>\w+)\@$/.match(arg)
      arg = matchdata[:ref].upcase.to_sym
      if @labels[arg]
        @labels[arg].parent = parent
        parent.addfields(fieldname => @labels[arg])
        obj = @labels[arg]
      else
        obj = classname.new fieldname: fieldname, label: label, arg: arg, parent: parent, source: self, user: @user
        @references[arg].push obj
      end
    else
      obj = classname.new fieldname: fieldname, label: label, arg: arg, parent: parent, source: self, user: @user
    end
    obj
  end

  def parsefile
    entrystack = []
    @labels = {:root => self}
    @references = Hash.new { |hash, key| hash[key] = []}
    @rawdata.split("\n").each do |line|
      if @head
        converter = @head.charset
      end
      if converter
        line = converter.convert(line)
      end
      matchdata = /^(?<depth>\d+)(\s+\@(?<label>\w+)\@)?\s*(?<fieldname>\w+)(\s(?<arg>.*))?/.match(line)
      depth = Integer matchdata[:depth]
      label = matchdata[:label] && matchdata[:label].upcase.to_sym
      fieldname = "#{matchdata[:fieldname].downcase}".to_sym
      if ENV['DEBUG']
        if label
          puts "#{' ' * depth} @#{label}@ #{fieldname} #{matchdata[:arg]}"
        else
          puts "#{' ' * depth} #{fieldname} #{matchdata[:arg]}"
        end
      end
      if depth > 0
        parent = entrystack[depth-1]
      else
        parent = nil
      end
      arg = matchdata[:arg] || ""
      entrystack[depth] = makeentry label, fieldname, arg, parent
    end
  end
  
  def addevent(event, date = event.date)
    if date
      @events[date.year][date.month][date.day][date.relative].push event
    else
      @events[999999][0][0][0].push event
    end
    if @husband
      @husband.addevent event, date
    end
    if @wife
      @wife.addevent event, date
    end
  end

  def delevent(event, date = event.date)
    if date
      @events[date.year][date.month][date.day][date.relative].delete_if {|i| i == event}
    else
      @events[999999][0][0][0].delete_if {|i| i == event}
    end
    if @husband
      @husband.delevent event, date
    end
    if @wife
      @wife.delevent event, date
    end
  end

  def to_s
    title
  end
end

class GedcomNote < GedcomEntry
  attr_reader :note

  def initialize(arg: "", **options)
    super(note: arg, **options)
  end

  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :cont
        @note += "\n" + value
        options.delete fieldname
      end
    end
    super(**options)
  end

  def to_s
    @title
  end
end

class GedcomTitl < GedcomString
end

class GedcomCont < GedcomString
end

class GedcomPage < GedcomEntry
  attr_reader :pageno
  attr_gedcom :source, :sour
  
  def initialize(arg: "", parent: nil, **options)
    @pageno = arg
    @source = parent
    #Change the source's parent to point to us instead of the source itself.
    @source.parent.delsource @source
    @source.parent.addsource self
  end

  def to_s
    "#{@source} Page #{@pageno}"
  end
end

class GedcomFam < GedcomEntry
  attr_gedcom :husband, :husb
  attr_reader :wife
  attr_reader :events
  attr_reader :children
  
  def initialize(**options)
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    @children = []
    super
  end
  
  def to_s
    if @husband
      husband = @husband
    else
      husband = "unknown"
    end
    if @wife
      wife = @wife
    else
      wife = "unknown"
    end
    "#{husband} and #{wife}"
  end

  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :husb
        @husband = value
        @children.each do |child|
          child.father = @husband
        end
        @events.keys.each do |year|
          @events[year].keys.each do |month|
            @events[year][month].keys.each do |day|
              @events[year][month][day].keys.each do |relative|
                @events[year][month][day][relative].each do |event|
                  @husband.addevent event
                end
              end
            end
          end
        end
        options.delete fieldname
      elsif fieldname == :wife
        @wife = value
        @children.each do |child|
          child.mother = @wife
        end
        @events.keys.each do |year|
          @events[year].keys.each do |month|
            @events[year][month].keys.each do |day|
              @events[year][month][day].keys.each do |relative|
                @events[year][month][day][relative].each do |event|
                  @wife.addevent event
                end
              end
            end
          end
        end
        options.delete fieldname
      elsif fieldname == :chil
        #puts "Adding #{fieldname} #{value.inspect} to #{self.inspect}"
        @children.push child
        if @husband
          value.father = @husband
          if value.birth
            @husband.addevent value.birth
          end
        end
        if @wife
          value.mother = @wife
          if value.birth
            @wife.addevent value.birth
          end
        end
        options.delete fieldname
      end
    end
    super(**options)
  end
  
  def addevent(event, date = event.date)
    if date
      @events[date.year][date.month][date.day][date.relative].push event
    else
      @events[999999][0][0][0].push event
    end
    if @husband
      @husband.addevent event, date
    end
    if @wife
      @wife.addevent event, date
    end
  end

  def delevent(event, date = event.date)
    if date
      @events[date.year][date.month][date.day][date.relative].delete_if {|i| i == event}
    else
      @events[999999][0][0][0].delete_if {|i| i == event}
    end
    if @husband
      @husband.delevent event, date
    end
    if @wife
      @wife.delevent event, date
    end
  end

  def showevents
    if @husband and @wife
      compareindividuals @husband, @wife
    elsif @husband
      @husband.showevents
    elsif @wife
      @wife.showevents
    end
  end
end

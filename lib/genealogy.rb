$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../lib")
require "genealogy/version"
require 'ansel'
require 'net/ldap'
require 'net/ldap/dn'
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
  attr_reader :basedn
  attr_reader :username
  attr_reader :dn
  attr_reader :objectfromdn
  attr_reader :attributemetadata

  def initialize(username: username, password: password)
    @basedn = 'dc=deepeddy,dc=com'
    @username = username
    @dn = Net::LDAP::DN.new "cn", @username, @basedn
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
    makeou "Names"
    makeou "Sources"
  end

  def makeou(ou, basedn=self.dn)
    oudn = Net::LDAP::DN.new "ou", ou, basedn
      attrs = {
        objectclass: ["top", "organizationalUnit"],
        ou: ou,
      }
      unless ldap.add dn: oudn, attributes: attrs
        message = ldap.get_operation_result.message
        unless message =~ /Entry Already Exists/
          raise "Couldn't add ou #{oudn.inspect} with attributes #{attrs.inspect}: #{message}"
        end
      end
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
        object = classfromentry(entry).new ldapentry: entry, user: self, dn: dn
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
    begin
      modified = @ldap.modify dn: dn, operations: ops
    rescue Exception => e
      raise "Failed to modify #{@dn.inspect} with operations #{ops.inspect}: #{e}"
    end
    unless modified
      message = @ldap.get_operation_result.message
      if message =~ /Attribute or Value Exists/
        #puts "Couldn't modify attributes #{ops} for #{dn}: #{message}"
      else
        puts "Couldn't modify attributes #{ops} for #{dn}: #{message}"
      end
    end
  end
  
  def findobjects(ldapclass, base)
    if block_given?
      unless @ldap.search(
        base: base,
      scope: Net::LDAP::SearchScope_SingleLevel,
      filter: Net::LDAP::Filter.eq("objectclass", ldapclass),
      deref: Net::LDAP::DerefAliases_Search,
      return_result: false,
      ) do |entry|
          object = classfromentry(entry).new ldapentry: entry, user: self
          @objectfromdn[object.dn] = object
          yield object
        end
        raise "Couldn't search #{@dn} for events: #{@ldap.get_operation_result.message}"
      end
    else
      objects = []
      findobjects(ldapclass, base) {|object|
        objects.push object
      }
      objects
    end
  end

  def findname(first: nil, last: nil)
    if first
      if matchdata = /^(?<realfirst>\S+)\s/.match(first)
        realfirst = matchdata[:realfirst]
        firstinit = first[0]
        dn = Net::LDAP::DN.new "givenName", first, "givenName", realfirst, "givenName", firstinit, "sn", last, "ou", "names", @dn
      else
        firstinit = first[0]
        if firstinit == first
          dn = Net::LDAP::DN.new "givenName", first, "sn", last, "ou", "names", @dn
        else
          dn = Net::LDAP::DN.new "givenName", first, "givenName", firstinit, "sn", last, "ou", "names", @dn
        end
      end
    else
      dn = Net::LDAP::DN.new "sn", last, "ou", "names", @dn
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
        events = findobjects('gedcomEvent', indi.dn).sort_by do |event|
          [event.year||9999, event.month||0, event.day||0, event.relativetodate||0]
        end.each do |event|
          puts "    #{event.date}\t#{event.description}\t#{event.place}"
        end
      end
      raise "Couldn't search #{@dn} for names: #{@ldap.get_operation_result.message}"
    end
  end

  def findtasks
    findobjects("*", Net::LDAP::DN.new("ou", "Tasks", basedn)) {|task|
      task.describeinfull
    }
  end
end

class LdapAlias
  attr_reader :dn

  def initialize(dn, user)
    @dn = dn
    @user = user
  end

  def object
    @user.objectfromdn[@dn]
  end

  def to_s
    object.to_s
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

  def self.fieldnametoclass(fieldname)
    if GedcomEntry.definedfieldnames.member? fieldname
      Module.const_get ("Gedcom" + fieldname.to_s.capitalize)
    else
      GedcomEntry
    end
  end
  
  def populatefromldap(ldapentry)
    ldapentry.each do |fieldname, value|
      syntax = @user.attributemetadata[fieldname][:syntax]
      if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
        value.map! {|dn| LdapAlias.new dn, @user}
      elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
        value.map! {|num| Integer(num)}
      elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
        value.map! {|val| (val == 'TRUE')}
      end
      fieldname = @@ldaptofield[self.class][fieldname] || @@ldaptofield[self.class.superclass][fieldname] || fieldname
      if @@multivaluevariables[self.class].include?(fieldname) || @@multivaluevariables[self.class.superclass].include?(fieldname)
        instance_variable_set "@#{fieldname}".to_sym, value
      else
        instance_variable_set "@#{fieldname}".to_sym, value[0]
      end
    end
    @dn = ldapentry.dn
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
        ref.parent.modifyfields(ref.fieldname => {ref => self})
      end
    end
    if ldapentry
      populatefromldap ldapentry
    elsif @user
      if @@classtoldapclass[self.class] || @@classtoldapclass[self.class.superclass]
        addtoldap
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
    else
      @noldapobject = true
    end
    [:uniqueidentifier, uid]
  end
  
  def basedn
    if @parent
      @parent.dn
    else
      @user.dn
    end
  end
  
  def addtoldap
    (rdnfield, rdnvalue) = self.rdn
    rdnfield = @@fieldtoldap[self.class][rdnfield] || @@fieldtoldap[self.class.superclass][rdnfield] || rdnfield
    unless @noldapobject
      if rdnvalue.is_a? Symbol
        puts "#{rdnfield.inspect} in #{self.inspect} is an unresolved reference (#{rdnvalue.inspect})"
      else
        @dn = Net::LDAP::DN.new rdnfield.to_s, rdnvalue, basedn
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
            if value.is_a? Array
              unless value == []
                attrs[ldapfieldname] = value.map {|v| v.kind_of?(GedcomEntry) ? v.dn : v}
              end
            else
              unless value == ""
                if value.kind_of? GedcomEntry
                  if value.dn
                    attrs[ldapfieldname] = value.dn.to_s
                  end
                else
                  attrs[ldapfieldname] = value
                end
              end
            end
          end
        end
        added = false
        dupcount = 0
        dupbase = dn
        while not added
          begin
            added = @user.ldap.add dn: @dn, attributes: attrs
          rescue Exception => e
            puts "Failed to add #{@dn.inspect} with attributes #{attrs.inspect}: #{e}"
            added = false
          end
          unless added
            message = @user.ldap.get_operation_result.message
            if message =~ /Entry Already Exists/
              dupcount += 1
              @dn = Net::LDAP::DN.new rdnfield.to_s, rdnvalue, @dn
            else
              raise "Couldn't add #{self.inspect} at #{@dn.inspect} with attributes #{attrs.inspect}: #{message}"
            end
          end
        end
        if dupcount == 1
          GedcomConflictingEvents.new baseevent: dupbase.to_s, user: @user
        end
      end
    end
  end

  def makealias(dest, rdnvalue=nil)
    if dest.dn
      if rdnvalue
        rdnfield = dest.rdn[0]
      else
        (rdnfield, rdnvalue) = dest.rdn
      end
      aliasdn = Net::LDAP::DN.new rdnfield.to_s, rdnvalue, self.dn
      attrs = {
        objectclass: ["alias", "extensibleObject"],
        aliasedobjectname: dest.dn.to_s,
      }
      attrs[rdnfield] = rdnvalue
      unless @user.ldap.add dn: aliasdn, attributes: attrs
        message = @user.ldap.get_operation_result.message
        if message =~ /Entry Already Exists/
          #puts "Couldn't add alias #{aliasdn.inspect} with attributes #{attrs.inspect}: #{message}"
        else
          raise "Couldn't add alias #{aliasdn.inspect} with attributes #{attrs.inspect}: #{message}"
        end
      end
    else
      puts "Can't add alias under #{dn.inspect} to #{dest.inspect} because the latter has no DN"
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
      if fieldname = (@@fieldtoldap[self.class][fieldname] || @@fieldtoldap[self.class.superclass][fieldname])
        (rdnfield, rdnvalue) = self.rdn
        if not(dn) and (rdnfield == fieldname)
          @dn = Net::LDAP::DN.new fieldname.to_s, value, basedn
          #puts "delayed addition of #{@dn} to ldap"
          self.addtoldap
        end
        if not(@noldapobject) and @user and @dn
          syntax = @user.attributemetadata[fieldname][:syntax]
          if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
            if value.dn
              ops.push [:add, fieldname, value.dn]
            end
          elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
            ops.push [:add, fieldname, value.to_s]
          elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
            ops.push [:add, fieldname, value.to_s.upcase]
          else
            ops.push [:add, fieldname, value]
          end
        end
      end
    end
    unless ops == []
      @user.modifyattributes @dn, ops
    end
  end
  
  def deletefields(**options)
    ops = []
    options.each do |fieldname, value|
      fieldname = @@gedcomtofield[self.class][fieldname] || @@gedcomtofield[self.class.superclass][fieldname] || fieldname
      if @@multivaluevariables[self.class].include?(fieldname) || @@multivaluevariables[self.class.superclass].include?(fieldname)
        if oldvalues = instance_variable_get("@#{fieldname}".to_sym)
          instance_variable_set "@#{fieldname}".to_sym, oldvalues.delete_if {|i| i == value}
        end
      else
        instance_variable_set "@#{fieldname}".to_sym, nil
      end
      if @user and @dn
        if fieldname = (@@fieldtoldap[self.class][fieldname] || @@fieldtoldap[self.class.superclass][fieldname])
          syntax = @user.attributemetadata[fieldname][:syntax]
          if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
            if value.dn
              ops.push [:delete, fieldname, value.dn]
            end
          elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
            ops.push [:delete, fieldname, value.to_s]
          elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
            ops.push [:delete, fieldname, value.to_s.upcase]
          else
            ops.push [:delete, fieldname, value]
          end
        end
      end
    end
    unless ops == []
      @user.modifyattributes @dn, ops
    end
  end
  
  def modifyfields(**options)
    ops = []
    options.each do |fieldname, valuepairs|
      valuepairs.each do |oldvalue, newvalue|
        fieldname = @@gedcomtofield[self.class][fieldname] || @@gedcomtofield[self.class.superclass][fieldname] || fieldname
        if @@multivaluevariables[self.class].include?(fieldname) || @@multivaluevariables[self.class.superclass].include?(fieldname)
          if oldvalues = instance_variable_get("@#{fieldname}".to_sym)
            instance_variable_set "@#{fieldname}".to_sym, oldvalues.delete_if {|i| i == oldvalue}
          end
        else
          instance_variable_set "@#{fieldname}".to_sym, nil
        end
        if @user and @dn
          if fieldname = (@@fieldtoldap[self.class][fieldname] || @@fieldtoldap[self.class.superclass][fieldname])
            syntax = @user.attributemetadata[fieldname][:syntax]
            if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
              if newvalue.dn
                ops.push [:replace, fieldname, [oldvalue.dn, newvalue.dn]]
              end
            elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
              ops.push [:delete, fieldname, [oldvalue.to_s, newvalue.to_s]]
            elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
              ops.push [:delete, fieldname, [oldvalue.to_s.upcase, newvalue.to_s.upcase]]
            else
              ops.push [:delete, fieldname, [oldvalue, newvalue]]
            end
          end
        end
      end
    end
    unless ops == []
      @user.modifyattributes @dn, ops
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
  attr_gedcom :charset, :char

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
                     year: year,
                     month: month,
                     day: day,
                     relativetodate: relative,
                     baddata: baddata)
  end
end

class GedcomPlac < GedcomEntry
  ldap_class :locality
  attr_reader :name
  attr_ldap :name, :l
  attr_reader :places
  attr_reader :events

  def initialize(ldapentry: nil, parent: nil, arg: "", user: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, user: user)
    else
      @user = user
      args = arg.split /\s*,\s*/
      dn = Net::LDAP::DN.new *(args.map {|i| ["l", i]}.flatten), basedn
      name = args[0]
      super(name: name, dn: dn, individual: parent, parent: parent, **options)
      makealias parent
    end
  end

  def addtoldap(dn=@dn)
    unless @user.ldap.search(
      base: dn,
      scope: Net::LDAP::SearchScope_BaseObject,
      return_result: false,
    )
      addtoldap Net::LDAP::DN.new *dn.to_a[2..999]
      attrs = {
        l: @name,
        objectclass: ["top", "locality"],
      }
      unless @user.ldap.add dn: dn, attributes: attrs
        raise "Couldn't add #{@name} at #{dn} with attributes #{attrs.inspect}: #{@user.ldap.get_operation_result.message}"
      end
    end
  end
  
  def basedn
    Net::LDAP::DN.new "ou", "Places", @user.basedn
  end
  
  def rdn
    @noldapobject = not(@name)
    [:l, @name]
  end
  
  def to_s
    parts = []
    Net::LDAP::DN.new(dn).each_pair do |key, val|
      if key == "description"
        parts.push val
      end
    end
    parts.join(', ')
  end
end

class GedcomEven < GedcomEntry
  ldap_class :gedcomevent
  attr_reader :date
  attr_ldap :date, :gedcomdate
  attr_reader :year
  attr_ldap :year, :year
  attr_reader :month
  attr_ldap :month, :month
  attr_reader :day
  attr_ldap :day, :day
  attr_reader :relativetodate
  attr_ldap :relativetodate, :relativetodate
  attr_ldap :baddata, :baddata
  attr_reader :place
  attr_gedcom :place, :plac
  attr_ldap :place, :placedn
  attr_reader :description
  attr_gedcom :description, :type
  attr_ldap :description, :description
  attr_reader :sources
  attr_gedcom :sources, :sour
  attr_ldap :sources, :sourcedns
  attr_reader :individual
  attr_ldap :individual, :individualdn

  def initialize(parent: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(individual: parent, parent: parent, **options)
    end
  end

  def to_s
    if date
      "#{@individual} #{@description} #{date} #{@place}"
    else
      "#{@individual} #{@description} ? #{@place}"
    end
  end

  def rdn
    @noldapobject = not(@description)
    [:description, @description]
  end
end

class GedcomBirt < GedcomEven
  ldap_class :gedcombirth

  def initialize(parent: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(individual: parent, parent: parent, description: "Birth of #{parent.fullname}", **options)
    end
  end
end

class GedcomDeat < GedcomEven
  ldap_class :gedcomdeath
  attr_gedcom :cause, :caus
  attr_ldap :cause, :cause

  def initialize(parent: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(individual: parent, parent: parent, description: "Death of #{parent.fullname}", **options)
    end
  end
end

class GedcomBuri < GedcomEven
  ldap_class :gedcomburial
  attr_reader :individual
  attr_ldap :individual, :individualdn

  def initialize(parent: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(individual: parent, parent: parent, description: "Burial of #{parent.fullname}", **options)
    end
  end
end

class GedcomMarr < GedcomEven
  ldap_class :gedcommarriage
  attr_ldap :couple, :couple
  attr_gedcom :officiator, :offi
  attr_ldap :officiator, :officiator

  def initialize(parent: nil, ldapentry: nil, **options)
    @parents = []
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      couple = []
      if parent.husband
        couple.push parent.husband
      end
      if parent.wife
        couple.push parent.wife
      end
      super(couple: couple, description: "Marriage of #{couple.map {|i| i.fullname}.join(' and ')}", **options)
      couple[1..999].each do |i|
        i.makealias self
      end
    end
  end

  def basedn
    @couple[0].dn
  end
end

class GedcomDiv < GedcomEven
  ldap_class :gedcomdivorce
  attr_ldap :couple, :couple

  def initialize(parent: nil, ldapentry: nil, **options)
    @parents = []
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      couple = []
      if parent.husband
        couple.push parent.husband
      end
      if parent.wife
        couple.push parent.wife
      end
      super(couple: couple, description: "Divorce of #{couple.map {|i| i.fullname}.join(' and ')}", **options)
      couple[1..999].each do |i|
        i.makealias self
      end
    end
  end

  def basedn
    @couple[0].dn
  end
end

class GedcomAdop < GedcomEven
  ldap_class :gedcomadoption
  attr_reader :parents
  attr_ldap :parents, :parentdns

  def initialize(parent: nil, ldapentry: nil, **options)
    @parents = []
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(individual: parent, parent: parent, description: "Adoption of #{parent.fullname}", **options)
    end
  end

  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :famc
        value.addfields(even: self)
        if value.respond_to?(:husband) and value.husband
          @parents.push value.husband
        end
        if value.respond_to?(:wife) and value.wife
          @parents.push value.wife
        end
        options.delete fieldname
      end
    end
    super(**options)
  end

  def deletefields(**options)
    options.each do |fieldname, value|
      if fieldname == :famc
        value.deletefields(even: self)
        if value.husband
          @parents.delete_if {|i| i == value.husband}
        end
        if value.wife
          @parents.delete_if {|i| i == value.wife}
        end
      end
    end
    super(**options)
  end
end

class GedcomBapm < GedcomEven
  ldap_class :gedcombaptism
  attr_reader :individual
  attr_ldap :individual, :individualdn

  def initialize(parent: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(individual: parent, parent: parent, description: "Baptism of #{parent.fullname}", **options)
    end
  end
end

class GedcomIndi < GedcomEntry
  ldap_class :gedcomindividual
  attr_ldap :gender, :sex
  attr_gedcom :birth, :birt
  attr_ldap :birth, :birthdn
  attr_reader :baptism
  attr_gedcom :death, :deat
  attr_ldap :death, :deathdn
  attr_accessor :mother
  attr_ldap :mother, :motherdn
  attr_accessor :father
  attr_ldap :father, :fatherdn
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

  def basedn
    Net::LDAP::DN.new "ou", "Individuals", @source.dn
  end
  
  def to_s
    if @birth and @birth.respond_to? :date
      birthdate = (@birth.date || '?')
    else
      birthdate = '?'
    end
    if @death and @death.respond_to? :date
        deathdate = (@death.date || '?')
    else
      deathdate = ''
    end
    "#{@fullname} #{birthdate} - #{deathdate}".rstrip
  end

  def birth
    @birth or GedcomBirt.new parent: self, fieldname: :birt, user: @user
  end
  
  def addfields(**options)
    newoptions = {}
    options.each do |fieldname, value|
      if fieldname == :name
        unless @fullname
          # If there are more than one name defined, populate with the first one; the others will be findable via the name objects
          if fullname = value.to_s
            newoptions[:fullname] = fullname
          end
          if first = value.first
            newoptions[:first] = first
          end
          if last = value.last
            newoptions[:last] = last
          end
          if suffix = value.suffix
            newoptions[:suffix] = suffix
          end
        end
      elsif fieldname == :buri
        options.delete fieldname
      elsif fieldname == :bapm
        options.delete fieldname
      elsif fieldname == :even
        if value and not self == value.parent
          if value.dn
            makealias value
          else
            puts "#{fieldname.inspect} #{value.inspect} (being added to #{self.inspect}) doesn't have a dn"
          end
        end
        options.delete fieldname
      elsif fieldname == :mother
        value.addfields(even: self.birth)
      elsif fieldname == :father
        value.addfields(even: self.birth)
      elsif fieldname == :sour
        @user.findobjects('gedcomEvent', @dn) do |event|
          event.addfields(sour: value)
        end
      end
    end
    newoptions.each do |fieldname, value|
      options[fieldname] = value
    end
    super(**options)
  end

  def deletefields(**options)
    options.each do |fieldname, value|
      if fieldname == :sour
        @user.findobjects('gedcomEvent', @dn) do |event|
          event.delfields(sour: value)
        end
      end
    end
    super(**options)
  end
end

class GedcomChar < GedcomEntry
  
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
    puts "#{arg} officiated at #{parent.inspect}"
#    parent.addfields(fieldname, $names[@last][@first][@suffix]])
  end
end

class GedcomName < GedcomEntry
  ldap_class :gedcomname
  attr_reader :first
  attr_ldap :first, :givenname
  attr_reader :last
  attr_ldap :last, :sn
  attr_reader :suffix
  attr_ldap :suffix, :initials
  attr_accessor :dn
  
  def initialize(arg: "", fieldname: fieldname, **options)
    (first, last, suffix) = arg.split(/\s*\/[\s*,]*/)
    if first == ''
      first = nil
    end
    if suffix == ''
      suffix = nil
    end
    super(fieldname: fieldname, first: first, last: last, suffix: suffix, **options)
  end
  
  def basedn
    Net::LDAP::DN.new "ou", "Names", @user.dn
  end
  
  def addtoldap
    dn=basedn
    if @last
      @last = @last.gsub /\*$/, ''
      dn = Net::LDAP::DN.new "sn", @last == '' ? 'unknown' : @last, dn
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
          dn = Net::LDAP::DN.new "givenName", firstinitial, dn
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

          if matchdata = /^(?<realfirst>\S+)\s/.match(@first)
            realfirst = matchdata[:realfirst]
            dn = Net::LDAP::DN.new "givenName", realfirst, dn
            unless @user.ldap.search(
              base: dn,
              scope: Net::LDAP::SearchScope_BaseObject,
              return_result: false,
            )
              attrs[:givenname] = realfirst
              unless @user.ldap.add dn: dn, attributes: attrs
                raise "Couldn't add first name #{realfirst} at #{dn} with attributes #{attrs.inspect}: #{@user.ldap.get_operation_result.message}"
              end
            end
          end
        end

        dn = Net::LDAP::DN.new "givenName", @first == '' ? 'unknown' : @first, dn
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
          dn = Net::LDAP::DN.new "initials", @suffix == '' ? 'unknown' : @suffix, dn
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
      makealias parent, parent.label.to_s
      @user.objectfromdn[dn] = self
    end
  end

  def to_s
    if @suffix
      "#{@first} /#{@last}/ #{@suffix}"
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

    def initialize(arg: nil, filename: nil, **options)
    @authors = []
    if filename
      super(filename: filename, title: File.basename(filename), rawdata: (File.read filename), **options)
      @user.makeou "Individuals", self.dn
      @user.makeou "Sources", self.dn
    else
      super(title: arg, **options)
    end
  end

  def basedn
    Net::LDAP::DN.new "ou", "Sources", (@source || @user).dn
  end
  
  def rdn
    if @title == ''
      super
    else
      @noldapobject = false
      [:title, @title]
    end
  end
  
  def addhead head
    @head = head
  end
  
  def makeentry(label, fieldname, arg, parent)
    parentclass = parent ? parent.class : self.class
    classname = parentclass.fieldnametoclass(fieldname)
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
  ldap_class :sourcepage
  attr_reader :pageno
  attr_ldap :pageno, :description
  attr_gedcom :source, :sour
  
  def initialize(arg: "", parent: nil, **options)
    if parent and parent.dn
      super(pageno: arg, source: parent, parent: parent, **options)
      #Change the source's parent to point to us instead of the source itself.
      @source.parent.modifyfields(sour: {parent => self})
    else
      super(arg: arg, **options)
    end
  end

  def source
    if @source
      @source
    else
      parentdn = Net::LDAP::DN.new *((Net::LDAP::DN.new dn).to_a[2..999])
      @user.objectfromdn[parentdn]
    end
  end
  
  def rdn
    @noldapobject = not(@pageno)
    [:pageno, pageno]
  end

  def to_s
    "#{source} Page #{@pageno}"
  end
end

class GedcomFam < GedcomEntry
  attr_reader :husband
  attr_gedcom :husband, :husb
  attr_reader :wife
  attr_reader :events
  attr_gedcom :events, :even
  attr_reader :children
  attr_gedcom :children, :chil
  
  def initialize(**options)
    @events = []
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
          child.addfields(father: @husband)
        end
        @events.each do |event|
          @husband.addfields(even: event)
        end
        options.delete fieldname
      elsif fieldname == :wife
        @wife = value
        @children.each do |child|
          child.addfields(mother: @wife)
        end
        @events.each do |event|
          @wife.addfields(even: event)
        end
        options.delete fieldname
      elsif fieldname == :chil
        @children.push value
        if @husband
          if value.father
            puts "Not adding #{@husband.inspect} as #{value.inspect}'s father because #{value.father.inspect} is already listed"
          else
            value.addfields(father: @husband)
          end
        end
        if @wife
          if value.mother
            puts "Not adding #{@wife.inspect} as #{self.inspect}'s mother because #{value.mother.inspect} is already listed"
          else
            value.addfields(mother: @wife)
          end
        end
        options.delete fieldname
      elsif fieldname == :even
        if @husband
          @husband.addfields(even: value)
        end
        if @wife
          @wife.addfields(even: value)
        end
      end
    end
    super(**options)
  end

  def deletefields(**options)
    options.each do |fieldname, value|
      if fieldname == :even
        if @husband
          @husband.deletefields(even: event)
        end
        if @wife
          @wife.deletefields(even: event)
        end
      end
    end
    super(**options)
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

class GedcomTask < GedcomEntry
  attr_ldap :uniqueidentifier, :uniqueidentifier

  @@counter = Time.new.to_i
  
  def basedn
    Net::LDAP::DN.new "ou", "Tasks", @user.basedn
  end
  
  def rdn
    @@counter += @@counter
    [:uniqueidentifier, "#{@user.username}-#{@@counter}"]
  end
end

class GedcomConflictingEvents < GedcomTask
  ldap_class :conflictingevents
  attr_reader :baseevent
  attr_ldap :baseevent, :eventdn

  def describeinfull
    puts "Conflicting records (#{@uniqueidentifier})"
    event = @baseevent.object
    while event
      puts "    #{event.to_s}"
      event = @user.findobjects(@@classtoldapclass[event.class], event.dn)[0]
    end
  end
  
  def to_s
    "Conflict at #{@baseevent}"
  end
end

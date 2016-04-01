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
  end

  def openldap
    @ldap.open do
      yield
    end
  end
  
  def addtoldap(obj, objectclass, parentdn=@dn)
    if obj.label
      uid = obj.label.to_s
    else
      uid = obj.title
    end
    obj.dn = "uniqueIdentifier=#{uid},#{parentdn}"
    attr = {
      uniqueidentifier: uid,
      objectclass: ["top", objectclass],
    }
    obj.ldapfields.each do |fieldname|
      if value = obj.instance_variable_get("@#{fieldname}".to_sym)
        unless value == []
          attr[fieldname] = value
        end
      end
    end
    unless @ldap.add dn: obj.dn, attributes: attr
      raise "Couldn't add #{obj.inspect} to #{self} with attributes #{attr.inspect}: #{@ldap.get_operation_result.message}"
    end
  end

  def addattribute(dn, attribute, value)
    if value.is_a? GedcomEntry
      if value.dn
        unless @ldap.add_attribute dn, attribute, value.dn
          raise "Couldn't add #{attribute} #{value.inspect} to #{dn}: #{@ldap.get_operation_result.message}"
        end
      end
    else
      unless @ldap.add_attribute dn, attribute, value
        raise "Couldn't add #{attribute} #{value.inspect} to #{dn}: #{@ldap.get_operation_result.message}"
      end
    end
  end
  
  def sources
    unless @sources
      @sources = []
      @ldap.search(
        base: @dn,
        scope: Net::LDAP::SearchScope_SingleLevel,
        filter: Net::LDAP::Filter.eq("objectclass", "gedcomSour"),
        return_result: false,
      ) do |entry|
        @sources.push GedcomSour.new ldapentry: entry, user: self
      end
    end
    @sources
  end
end

class GedcomEntry
  attr_reader :fieldname
  attr_reader :label
  attr_reader :arg
  attr_accessor :parent
  attr_reader :baddata
  attr_accessor :dn

  def initialize(fieldname: "", label: nil, arg: "", parent: nil, user: nil, source: nil, ldapentry: nil, **options)
    if ldapentry
      ldapentry.each do |fieldname, value|
        fieldname = @@ldaptofield[self.class][fieldname] || fieldname
        if @@multivaluevariables[self.class].include? fieldname
          instance_variable_set "@#{fieldname}".to_sym, value
        else
          instance_variable_set "@#{fieldname}".to_sym, value[0]
        end
      end
    end
    if user
      @user = user
    end
    if label
      @label = label
      source.labels[@label] = self
      source.references[@label].each do |ref|
        ref.parent.delfield ref.fieldname, ref
        ref.parent[ref.fieldname] = self
      end
    end
    if fieldname
      @fieldname = fieldname
    end
    if arg
      @arg = arg
    end
    if parent
      @parent = parent
      parent[fieldname] = self
    end
  end

  def to_s
    "#{@label} #{@fieldname} #{arg}"
  end

  @@multivaluevariables = Hash.new { |hash, key| hash[key] = Set.new}
  @@gedcomtofield = Hash.new { |hash, key| hash[key] = Hash.new}
  @@fieldtoldap = Hash.new { |hash, key| hash[key] = Hash.new}
  @@ldaptofield = Hash.new { |hash, key| hash[key] = Hash.new}

  def ldapfields
    @@fieldtoldap[self.class].keys
  end

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
  
  def inspect
    if @baddata
      "#<#{self.class}: #{to_s} :BAD>"
    else
      "#<#{self.class}: #{to_s}>"
    end
  end
  
  def []=(fieldname, value)
    fieldname = @@gedcomtofield[self.class][fieldname] || fieldname
    if @@multivaluevariables[self.class].include? fieldname
      if oldvalues = instance_variable_get("@#{fieldname}".to_sym)
        instance_variable_set "@#{fieldname}".to_sym, oldvalues + [value]
      else
        instance_variable_set "@#{fieldname}".to_sym, [value]
      end
    else
      instance_variable_set "@#{fieldname}".to_sym, value
    end
    if @user
      if fieldname = @@fieldtoldap[self.class][fieldname]
        @user.addattribute @dn, fieldname, value
      end
    end
  end
  
  def delfield(fieldname, value)
    if @@multivaluevariables[self.class].include? fieldname
      if oldvalues = instance_variable_get("@#{fieldname}".to_sym)
        instance_variable_set "@#{fieldname}".to_sym, oldvalues.delete_if {|i| i == value}
      end
    else
      instance_variable_set "@#{fieldname}".to_sym, nil
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
      @parent = source
    end
    super
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
    @address = arg
    @phones = []
    super
  end
  
  def []=(fieldname, child)
    if fieldname == :cont
      @address += "\n" + child
    else
      super
    end
  end
end

class GedcomString < GedcomEntry
  def initialize(fieldname: "", arg: "", parent: nil,**options)
    parent[fieldname] = arg
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
    @raw = arg
    args = arg.split(/\s+/)
    @relative = 0
    if args[0] == 'AFT'
      @relative = +10
      args.shift
    elsif args[0] == 'BEF'
      @relative = -10
      args.shift
    elsif args[0] == 'ABT'
      @relative = +1
      args.shift
    elsif args[0] == 'BET'
      @relative = +2
      args.shift
      args = args[0..(args.index("AND")-1)]
    end
    @year = args.pop
    if (@year =~ /[^\d]/)
      @baddata = true
      @year = Integer(@year[/^\d+/]||0)
    else
      @year = Integer(@year)
    end
    if @month = args.pop
      unless @month = Monthmap[@month]
        @baddata = true
        @month = 0
      end
    else
      @month = 0
    end
    @day = args.pop
    @day = Integer(@day || 0)
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    addevent parent
    super
    if @parent.parent
      @parent.parent.delevent parent, nil
      @parent.parent.addevent parent, self
    end
    #puts self.inspect
    end

  def to_s
    @raw
  end

  def addevent(event, date = event.date)
    if date
      @events[date.year][date.month][date.day][date.relative].push event
    else
      @events[999999][0][0][0].push event
    end
  end

  def delevent(event, date = event.date)
    if date
      @events[date.year][date.month][date.day][date.relative].delete_if {|i| i == event}
    else
      @events[999999][0][0][0].delete_if {|i| i == event}
    end
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
      parent[fieldname] = place
    end
  end
  
  def addplace(place)
    @places[place.name] = place
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

  def to_s
    if parent
      "#{@rawname}, #{parent}"
    else
      "#{@rawname}"
    end
  end
end

class GedcomEven < GedcomEntry
  attr_reader :date
  attr_gedcom :place, :plac
  attr_reader :description
  attr_reader :sources
  attr_gedcom :type, :description

  def initialize(source: nil, **options)
    super
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

  def []=(fieldname, value)
    if fieldname == :sour
      addsource value
    else
      super
    end
  end

  def addsource(source)
    self[:sources] = source
  end

  def delsource(source)
    delfield :sources, source
  end
end

class GedcomBirt < GedcomEven
  attr_reader :individual

  def initialize(parent: nil, **options)
    @individual = parent
    super
  end

  def to_s
    if date
      "#{@individual.names[0]} #{date} #{@place}"
    else
      "#{@individual.names[0]} #{@place}"
    end
  end
end

class GedcomDeat < GedcomEven
  attr_reader :individual
  attr_gedcom :cause, :caus

  def initialize(parent: nil, **options)
    super
    @individual = parent
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
    super
    @individual = parent
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
    super
    @individual = parent
    @parents = []
  end

  def []=(fieldname, value)
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
    else
      super
    end
  end

  def delfield(fieldname, value)
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

  def to_s
    @individual.to_s
  end
end

class GedcomBapm < GedcomEven
end

class GedcomIndi < GedcomEntry
  attr_reader :gender, :sex
  attr_gedcom :birth, :birt
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
  attr_ldap :cn, :cn
  attr_ldap :first, :givenname
  attr_ldap :last, :sn
  attr_ldap :suffix, :initials

  def initialize(source: nil, **options)
    #puts "#{self.class} #{arg.inspect}"
    @names = []
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    super
    @user.addtoldap self, "gedcomIndi", source.dn
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
    "#{@names[0]} #{birthdate} - #{deathdate}"
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
    self[:sources] = source
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
    delfield :sources, source
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
  
  def []=(fieldname, value)
    if fieldname == :name
      super 
      if cn = value.to_s
        self[:cn] = cn
      end
      if first = value.first
        self[:first] = first
      end
      if last = value.last
        self[:last] = last
      end
      if suffix = value.suffix
        self[:suffix] = suffix
      end
    elsif fieldname == :birt
      super
      addevent value, nil
    elsif fieldname == :deat
      super
      addevent value, nil
    elsif fieldname == :buri
      addevent value, nil
    elsif fieldname == :bapm
      addevent value, nil
    elsif fieldname == :even
      addevent value, nil
    elsif fieldname == :adop
      addevent value, nil
    elsif fieldname == :sour
      addsource value
    else
      super
    end
  end
end

class GedcomChar < GedcomEntry
  attr_reader :charset
  
  def initialize(fieldname: nil, arg: "", parent: nil, **options)
    if arg == 'ANSEL'
      parent[fieldname] = ANSEL::Converter.new
    else
      raise "Don't know what to do with #{arg} encoding"
    end
  end
end

class GedcomOffi < GedcomEntry
  def initialize(arg: "", parent: nil, **options)
    (@first, @last, @suffix) = arg.split(/\s*\/\s*/)
    parent[fieldname] = $names[@last][@first][@suffix]
  end
end

class GedcomName < GedcomEntry
  attr_reader :first
  attr_reader :last
  attr_reader :suffix
  
  def initialize(arg: "", **options)
    (@first, @last, @suffix) = arg.split(/\s*\/\s*/)
    $names[@last][@first][@suffix] = self
    super
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
    parent[fieldname] = gender
  end
  
  def to_s
    @gender
  end
end

class GedcomType < GedcomString
end

class GedcomSour < GedcomEntry
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

  def initialize(arg: nil, filename: nil, parent: nil, source: nil, ldapentry: nil, **options)
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    @authors = []
    if filename
      @filename = filename
      @title = filename
      @rawdata = File.read filename
    else
      @parent = source
      unless arg == ""
        @title = arg
      end
    end
    super
    unless ldapentry
      if @user
        if @parent
          @user.addtoldap self, "gedcomSour", @parent.dn
        else
          @user.addtoldap self, "gedcomSour"
        end
      end
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
        parent[fieldname] = @labels[arg]
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
    @note = arg
  end

  def []=(fieldname, value)
    if fieldname == :cont
      @note += "\n" + value
    else
      super
    end
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

  def []=(fieldname, value)
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
    else
      super
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

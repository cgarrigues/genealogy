$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../lib")
require "genealogy/version"
require 'ansel'

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

class GedcomEntry
  attr_reader :command
  attr_reader :label
  attr_reader :arg
  attr_accessor :parent
  attr_reader :children
  attr_reader :baddata

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    @command = command
    @label = label
    @arg = arg
    if parent
      @parent = parent
      parent.addchild command, self
    end
    @children = Hash.new { |hash, key| hash[key] = []}
    if @label
      source.labels[@label] = self
      source.references[@label].each do |ref|
        ref.parent.delchild ref.command, ref
        ref.parent.addchild ref.command, self
      end
    end
  end

  def to_s
    "#{@label} #{@command} #{arg} #{children}"
  end

  def inspect
    if @baddata
      "#<#{self.class}: #{to_s} :BAD>"
    else
      "#<#{self.class}: #{to_s}>"
    end
  end
  
  def addchild(command, child)
    unless command == :CHIL
      puts "Adding #{command} #{child.inspect} to #{self.inspect}"
    end
    @children[command].push child
  end
  
  def delchild(command, child)
    puts "Deleting #{command} #{child.inspect} from #{self.inspect}"
    @children[command].delete_if {|i| i == child}
  end
  
  def self.definedcommands
    ObjectSpace.each_object(Class).select { |klass| klass < self }.map {|i| i.to_s[6,999].upcase.to_sym}
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

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    if source
      source.addhead self
    end
    super
  end
  
  def addchild(command, child)
    if command == :SOUR
      @source = child
    elsif command == :DEST
      @destination = child
    elsif command == :DATE
      @date = child
    elsif command == :SUBM
      @subm = child
    elsif command == :FILE
      @file = child
    elsif command == :GEDC
      @gedcom = child
    elsif command == :CHAR
      @charset = child
    else
      super
    end
  end

  def delchild(command, child)
    if command == :SUBM
    else
      super
    end
  end
end

class GedcomGedc < GedcomEntry
  attr_reader :version
  attr_reader :form

  def addchild(command, child)
    if command == :VERS
      @version = child
    elsif command == :FORM
      @form = child
    else
      super
    end
  end
end

class GedcomSubm < GedcomEntry
  attr_reader :name
  attr_reader :address

  def addchild(command, child)
    if command == :NAME
      @name = child
    elsif command == :ADDR
      @address = child
    else
      super
    end
  end
end

class GedcomAddr < GedcomEntry
  attr_reader :address
  attr_reader :phones

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    @address = arg
    @phones = []
    super
  end
  
  def addchild(command, child)
    if command == :CONT
      @address += "\n" + child
    elsif command == :PHON
      @phones.push child
    else
      super
    end
  end
end

class GedcomString < GedcomEntry
  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    parent.addchild command, arg
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
  
  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
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

  def initialize(command: nil, label: nil, arg: "", parent: nil, child: nil, source: nil)
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    super
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
  def initialize(command: nil, label: nil, arg: "", parent: nil, child: nil, source: nil)
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
      parent.addchild command, place
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
  attr_reader :place
  attr_reader :description
  attr_reader :sources

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
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

  def addchild(command, child)
    if command == :DATE
      @date = child
    elsif command == :PLAC
      @place = child
    elsif command == :TYPE
      @description = child
    elsif command == :SOUR
      addsource child
    else
      super
    end
  end

  def addsource(source)
    @sources.push source
  end

  def delsource(source)
    @sources.delete_if {|i| i == source}
  end
end

class GedcomBirt < GedcomEven
  attr_reader :individual

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    super
    @individual = parent
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
  attr_reader :cause

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    super
    @individual = parent
  end

  def addchild(command, child)
    if command == :CAUS
      @cause = child
    else
      super
    end
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

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
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
  attr_reader :officiator

  def addchild(command, child)
    if command == :OFFI
      @officiator = child
    else
      super
    end
  end

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

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    super
    @individual = parent
    @parents = []
  end

  def addchild(command, child)
    if command == :FAMC
      if child.respond_to? :addevent
        child.addevent self, @date
        if child.husband
          @parents.push child.husband
        end
        if child.wife
          @parents.push child.wife
        end
      end
    else
      super
    end
  end

  def delchild(command, child)
    if command == :FAMC
      if child.respond_to? :delevent
        child.delevent self, @date
        if child.husband
          @parents.delete_if {|i| i == child.husband}
        end
        if child.wife
          @parents.delete_if {|i| i == child.wife}
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
  attr_reader :names
  attr_reader :sex
  attr_reader :birth
  attr_reader :baptism
  attr_reader :death
  attr_accessor :mother
  attr_accessor :father
  attr_reader :events

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
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
    "#{names[0]} #{birthdate} - #{deathdate}"
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
  
  def addchild(command, child)
    if command == :NAME
      @names.push child
    elsif command == :SEX
      @sex = child
    elsif command == :BIRT
      @birth = child
      addevent child, nil
    elsif command == :DEAT
      @death = child
      addevent child, nil
    elsif command == :BURI
      addevent child, nil
    elsif command == :BAPM
      addevent child, nil
    elsif command == :EVEN
      addevent child, nil
    elsif command == :ADOP
      addevent child, nil
    elsif command == :FAMS
    elsif command == :FAMC
    elsif command == :SOUR
      addsource child
    else
      super
    end
  end

  def delchild(command, child)
    if command == :FAMS
    elsif command == :FAMC
    else
      super
    end
  end
end

class GedcomChar < GedcomEntry
  attr_reader :charset
  
  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    if arg == 'ANSEL'
      parent.addchild command, ANSEL::Converter.new
    else
      raise "Don't know what to do with #{arg} encoding"
    end
  end
end

class GedcomOffi < GedcomEntry
  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    (@first, @last, @suffix) = arg.split(/\s*\/\s*/)
    parent.addchild command, $names[@last][@first][@suffix]
  end
end

class GedcomName < GedcomEntry
  attr_reader :first
  attr_reader :last
  attr_reader :suffix
  
  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    (@first, @last, @suffix) = arg.split(/\s*\/\s*/)
    $names[@last][@first][@suffix] = self
    super
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
  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    if /^m/i.match(arg)
      gender = :male
    elsif /^f/i.match(arg)
      gender = :female
    else
      gender = arg
    end
    parent.addchild command, gender
  end
  
  def to_s
    @gender
  end
end

class GedcomType < GedcomString
end

class GedcomSour < GedcomEntry
  attr_reader :version
  attr_reader :title
  attr_reader :note
  attr_reader :events
  attr_reader :corp
  attr_reader :author
  attr_reader :publication
  attr_reader :filename
  attr_reader :head
  attr_reader :labels
  attr_reader :references
  attr_reader :rawdata

  def initialize(command: "", label: nil, arg: "", parent: nil, filename: nil, source: nil)
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
    @authors = []
    if filename
      @filename = filename
      @title = filename
      @rawdata = File.readlines filename
    else
      super command: command, label: label, arg: arg, parent: parent, source: source
    end
  end

  def addhead head
    @head = head
  end
  
  def makeentry(label, command, arg, parent)
    if GedcomEntry.definedcommands.member? command
      classname = Module.const_get ("Gedcom" + command.to_s.capitalize)
    else
      classname = GedcomEntry
    end
    if matchdata = /^\@(?<ref>\w+)\@$/.match(arg)
      arg = matchdata[:ref].upcase.to_sym
      if @labels[arg]
        @labels[arg].parent = parent
        parent.addchild command, @labels[arg]
        obj = @labels[arg]
      else
        obj = classname.new command: command, label: label, arg: arg, parent: parent, source: self
        @references[arg].push obj
      end
    else
      obj = classname.new command: command, label: label, arg: arg, parent: parent, source: self
    end
    obj
  end

  def parsefile
    entrystack = []
    @labels = {}
    @references = Hash.new { |hash, key| hash[key] = []}
    @rawdata.each do |line|
      if @head
        converter = @head.charset
      end
      if converter
        line = converter.convert(line)
      end
      matchdata = /^(?<depth>\d+)(\s+\@(?<label>\w+)\@)?\s*(?<command>\w+)(\s(?<arg>.*))?/.match(line)
      depth = Integer matchdata[:depth]
      label = matchdata[:label] && matchdata[:label].upcase.to_sym
      command = matchdata[:command].upcase.to_sym
#      if label
#        puts "#{' ' * depth} @#{label}@ #{command} #{matchdata[:arg]}"
#      else
#        puts "#{' ' * depth} #{command} #{matchdata[:arg]}"
#      end
      if depth > 0
        parent = entrystack[depth-1]
      else
        parent = nil
      end
      arg = matchdata[:arg] || ""
      entrystack[depth] = makeentry label, command, arg, parent
    end
  end
  
  def addchild(command, child)
    if command == :TITL
      @title = child
    elsif command == :VERS
      @version = child
    elsif command == :CORP
      @corp = child
    elsif command == :NOTE
      @note = child
    elsif command == :PUBL
      @publication = child
    elsif command == :AUTH
      @authors.push child
    else
      super
    end
  end
  
  def to_s
    @title
  end
end

class GedcomNote < GedcomEntry
  attr_reader :note

  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    @note = arg
  end

  def addchild(command, child)
    if command == :CONT
      @note += "\n" + child
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
  attr_reader :source
  
  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
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
  attr_reader :husband
  attr_reader :wife
  attr_reader :events
  
  def initialize(command: "", label: nil, arg: "", parent: nil, source: nil)
    @events = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = Hash.new { |hash, key| hash[key] = [] }}}}
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

  def addchild(command, child)
    if command == :HUSB
      @husband = child
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
    elsif command == :WIFE
      @wife = child
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
    elsif command == :MARR
      #puts "Adding #{command} #{child.inspect} to #{self.inspect}"
    elsif command == :DIV
      #puts "adding #{command} #{child.inspect} to #{self.inspect}"
    elsif command == :EVEN
      #puts "Adding #{command} #{child.inspect} to #{self.inspect}"
    elsif command == :NAME
      #puts "Adding #{command} #{child.inspect} to #{self.inspect}"
    elsif command == :CHIL
      #puts "Adding #{command} #{child.inspect} to #{self.inspect}"
      super
      if @husband
        child.father = @husband
        if child.birth
          @husband.addevent child.birth
        end
      end
      if @wife
        child.mother = @wife
        if child.birth
          @wife.addevent child.birth
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

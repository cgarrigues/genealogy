$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../lib")
require 'genealogy/version'
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

class Array
  def === (foo)
    if length == foo.length
      (0..length).all? {|i| self[i] === foo[i]}
    else
      false
    end
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
      Entry.getclassfromldapclass ldapclass
    end
    Entry.getclassfromldapclass ldapclass
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
        # It's okay that this attribute is already here
      else
        raise "Couldn't modify attributes #{ops} for #{dn}: #{message}"
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
        raise "Couldn't search #{base} for events: #{@ldap.get_operation_result.message}"
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
    findobjects("*", Net::LDAP::DN.new("ou", "Tasks", basedn)).each {|task|
      task.describeinfull
    }
  end

  def runtasks
    findobjects("*", Net::LDAP::DN.new("ou", "Tasks", basedn)).each {|task|
      task.runtask
    }
  end
end

class LdapAlias
  attr_reader :dn

  def initialize(dn, user)
    @dn = dn
    @user = user
  end

  def === (foo)
    dn.to_s === foo.dn.to_s
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

class Entry

  class << self

    @@multivaluefields = Hash.new { |hash, key| hash[key] = Set.new}
    @@gedcomtofield = Hash.new { |hash, key| hash[key] = Hash.new}
    @@fieldtoldap = Hash.new { |hash, key| hash[key] = Hash.new}
    @@ldaptofield = Hash.new { |hash, key| hash[key] = Hash.new}
    @@classtoldapclass = Hash.new
    @@ldapclasstoclass = Hash.new
    
    def attr_multi(fieldname)
      @@multivaluefields[self].add fieldname
    end
    
    def attr_gedcom(fieldname, gedcomname)
      @@gedcomtofield[self][gedcomname] = fieldname
    end
    
    def attr_ldap(fieldname, ldapname)
      @@fieldtoldap[self][fieldname] = ldapname
      @@ldaptofield[self][ldapname] = fieldname
    end
    
    def ldap_class(ldapclass)
      @@classtoldapclass[self] = ldapclass
      @@ldapclasstoclass[ldapclass] = self
    end
    
    def getclassfromldapclass(ldapclass)
      @@ldapclasstoclass[ldapclass]
    end
    
    def fieldnametoclass(fieldname)
      if [:auth, :cause, :corp, :file, :form, :phon, :publ, :title, :description, :version].member? fieldname
        StringArgument
      elsif fieldname == :address
        Address
      elsif fieldname == :charset
        CharacterSet
      elsif fieldname == :head
        Head
      elsif fieldname == :indi
        Individual
      elsif fieldname == :notes
        Note
      elsif fieldname == :pages
        Page
      elsif fieldname == :sources
        Source
      else
        Entry
      end
    end
    
    def ldaptofield(fieldname)
      klass = self
      newfield = nil
      until klass == Object do
        newfield ||= @@ldaptofield[klass][fieldname]
        klass = klass.superclass
      end
      newfield
    end
    
    def gedcomtofield(fieldname)
      klass = self
      newfield = nil
      until klass == Object do
        newfield ||= @@gedcomtofield[klass][fieldname]
        klass = klass.superclass
      end
      newfield
    end
    
    def classtoldapclass
      klass = self
      ldapclass = nil
      until klass == Object do
        ldapclass ||= @@classtoldapclass[klass]
        klass = klass.superclass
      end
      ldapclass
    end
    
    def multivaluefield(fieldname)
      multivalue = false
      klass = self
      until klass == Object do
        multivalue ||= @@multivaluefields[klass].include?(fieldname)
        klass = klass.superclass
      end
      multivalue
    end
    
    def ldapfields
      fields = Set.new
      klass = self
      until klass == Object do
        fields += @@fieldtoldap[klass].keys
        klass = klass.superclass
      end
      fields
    end
    
    def fieldtoldap(fieldname)
      klass = self
      ldapfield = nil
      until klass == Object do
        ldapfield ||= @@fieldtoldap[klass][fieldname]
        klass = klass.superclass
      end
      ldapfield
    end
    
    def allldapclasses
      klass = self
      ldapclasses = ["Top"]
      until klass == Object do
        if ldapclass = @@classtoldapclass[klass]
          ldapclasses.push ldapclass.to_s
        end
        klass = klass.superclass
      end
      ldapclasses
    end
  end
  
  attr_reader :fieldname
  attr_reader :label
  attr_reader :arg
  attr_accessor :superior
  attr_reader :baddata
  attr_accessor :dn
  attr_multi :sources

  def === (foo)
    dn.to_s === foo.dn.to_s
  end
  
  def populatefromldap(ldapentry)
    ldapentry.each do |fieldname, value|
      syntax = @user.attributemetadata[fieldname][:syntax]
      if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
        # DN
        value.map! {|dn| LdapAlias.new Net::LDAP::DN.new(dn), @user}
      elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
        # Integer
        value.map! {|num| Integer(num)}
      elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
        # Boolean
        value.map! {|val| (val == 'TRUE')}
      end
      fieldname = self.class.ldaptofield(fieldname) || fieldname
      if self.class.multivaluefield(fieldname)
        instance_variable_set "@#{fieldname}".to_sym, value
      else
        instance_variable_set "@#{fieldname}".to_sym, value[0]
      end
    end
    @dn = Net::LDAP::DN.new ldapentry.dn
  end

  def initialize(ldapentry: nil, **options)
    @tasks = []
    options.each do |fieldname, value|
      if value
        fieldname = self.class.ldaptofield(fieldname) || fieldname
        if self.class.multivaluefield(fieldname)
          if value.is_a? Array
            instance_variable_set "@#{fieldname}".to_sym, value
          else
            instance_variable_set "@#{fieldname}".to_sym, [value]
          end
        else
          instance_variable_set "@#{fieldname}".to_sym, value
        end
      end
    end
    if @label
      @sources[0].label[@label] = self
      @sources[0].references[@label].each do |ref|
        iv = ref.superior.getinstancevariable(ref.fieldname)
        if iv
          ref.superior.modifyfields(ref.fieldname => {iv => self})
        else
          ref.superior.addfields(ref.fieldname => self)
        end
      end
    end
    if ldapentry
      populatefromldap ldapentry
    elsif @user
      if self.class.classtoldapclass
        addtoldap
      end
    end
    if @superior
      if @superior.class.multivaluefield(fieldname)
        iv = @superior.getinstancevariable(fieldname)
        unless (iv and iv.any? {|v| v === self})
          @superior.addfields(fieldname => self)
        end
      else
        @superior.addfields(fieldname => self)
      end
    end
  end

  def to_s
    "#{@label} #{@fieldname} #{arg}"
  end

  def rdn
    unless @uniqueidentifier
      if @label
        @uniqueidentifier = @label.to_s
        @noldapobject = false
      else
        @noldapobject = true
      end
    end
    [:uniqueidentifier, @uniqueidentifier]
  end
  
  def basedn
    if @superior
      @superior.dn
    else
      @user.dn
    end
  end
  
  def addtoldap
    (rdnfield, rdnvalue) = self.rdn
    rdnfield = self.class.fieldtoldap(rdnfield) || rdnfield
    unless @noldapobject
      if rdnvalue.is_a? Symbol
        puts "#{rdnfield.inspect} in #{self.inspect} is an unresolved reference (#{rdnvalue.inspect})"
      else
        @dn = Net::LDAP::DN.new rdnfield.to_s, rdnvalue, basedn
        @user.objectfromdn[@dn] = self
        attrs = {}
        attrs[:objectclass] = self.class.allldapclasses
        attrs[rdnfield] = rdnvalue
        self.class.ldapfields.each do |fieldname|
          ldapfieldname = self.class.fieldtoldap(fieldname) || fieldname
          if value = getinstancevariable(fieldname)
            if value == ""
              value = []
            else
              unless value.is_a? Array
                value = [value]
              end
              unless value == []
                syntax = @user.attributemetadata[ldapfieldname][:syntax]
                attrs[ldapfieldname] = value.map do |value|
                  if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
                    # DN
                    if value.is_a? String
                      value
                    else
                      value.dn
                    end
                  elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
                    # Integer
                    value.to_s
                  elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
                    # Boolean
                    value.to_s.upcase
                  else
                    value
                  end
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
              raise "Couldn't add #{self.inspect} at #{@dn} with attributes #{attrs.inspect}: #{message}"
            end
          end
        end
        if dupcount == 1
          ConflictingEntries.new baseentry: dupbase.to_s, user: @user
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
      aliasdn = Net::LDAP::DN.new rdnfield.to_s, rdnvalue, dn
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
      puts "Can't add alias under #{dn} to #{dest.inspect} because the latter has no DN"
    end
  end

  def fixreferences(old, new)
    @tasks.each do |task|
      task.object.updatedns old, new
    end
  end
  
  def renameandmoveto(newsuperior)
    puts newsuperior
    (rdnfield, rdnvalue) = rdn
    newrdn = Net::LDAP::DN.new rdnfield.to_s, getnewrdn
    newdn = Net::LDAP::DN.new rdnfield.to_s, getnewrdn, newsuperior
    puts "Renaming #{dn}"
    puts "      to #{newdn}"
    fixreferences self, newdn
    unless @user.ldap.rename(olddn: self.dn, newrdn: newrdn, delete_attributes: true, new_superior: newsuperior)
      raise "Couldn't rename #{self.dn} to #{newdn}"
    end
  end
  
  def updatedns(from, to)
    raise "Not mapping #{from.dn} to #{to} in #{self.inspect}"
  end

  def inspect
    if @baddata
      "#<#{self.class}: #{to_s} :BAD>"
    else
      "#<#{self.class}: #{to_s}>"
    end
  end

  def setinstancevariable(fieldname, value)
    if self.class.multivaluefield(fieldname)
      if oldvalues = getinstancevariable(fieldname)
        instance_variable_set "@#{fieldname}".to_sym, oldvalues + [value]
      else
        instance_variable_set "@#{fieldname}".to_sym, [value]
      end
    else
      instance_variable_set "@#{fieldname}".to_sym, value
    end
  end
  
  def getinstancevariable(fieldname)
    instance_variable_get("@#{fieldname}".to_sym)
  end
  
  def addldapops(fieldname, value)
    ops = []
    (rdnfield, rdnvalue) = rdn
    if fieldname = self.class.fieldtoldap(fieldname)
      if not(dn) and (rdnfield == fieldname)
        @dn = Net::LDAP::DN.new fieldname.to_s, value, basedn
        #puts "Delayed addition of #{@dn} to ldap"
        self.addtoldap
      end
      if not(@noldapobject) and @user and @dn
        syntax = @user.attributemetadata[fieldname][:syntax]
        if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
          # DN
          if value.is_a? Net::LDAP::DN
            ops.push [:add, fieldname, value]
          elsif value.dn
            ops.push [:add, fieldname, value.dn]
          end
        elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
          # Integer
          ops.push [:add, fieldname, value.to_s]
        elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
          # Boolean
          ops.push [:add, fieldname, value.to_s.upcase]
        else
          ops.push [:add, fieldname, value]
        end
      end
    end
    return ops
  end
  
  def addfields(**options)
    ops = []
    options.each do |fieldname, value|
      iv = getinstancevariable(fieldname)
      if self.class.multivaluefield(fieldname)
        if iv and iv.any? {|v| v === value}
          raise "Trying to add #{value.inspect} to #{fieldname.inspect} in #{self.inspect}, but it is already defined (#{iv.inspect})"
        else
          setinstancevariable fieldname, value
          ops.concat addldapops fieldname, value
        end
      else
        if iv and not (iv == "")
          if value === iv
            raise "Trying to add #{value.inspect} to #{fieldname.inspect} in #{self.inspect}, but it is already defined"
          else
            raise "Trying to add #{value.inspect} to #{fieldname.inspect} in #{self.inspect}, but it is already defined as #{iv.dn}"
          end
        else
          setinstancevariable fieldname, value
          ops.concat addldapops fieldname, value
        end
      end
    end
    unless ops == []
      begin
        @user.modifyattributes @dn, ops
      rescue RuntimeError => e
        options.each do |fieldname, value|
          ErrorAddingField.new superiorentry: self, fieldname: fieldname.to_s, newvalue: value, user: @user
        end
      end
    end
  end

  def deleteinstancevariable(fieldname, value)
    if self.class.multivaluefield(fieldname)
      if oldvalues = getinstancevariable(fieldname)
        instance_variable_set "@#{fieldname}".to_sym, oldvalues.delete_if {|i| i == value}
      end
    else
      instance_variable_set "@#{fieldname}".to_sym, nil
    end
  end

  def deletefields(**options)
    ops = []
    options.each do |fieldname, value|
      iv = getinstancevariable(fieldname)
      deleteinstancevariable fieldname, value
      if not iv
        raise "Trying to delete #{value.inspect} from #{fieldname} in #{self.inspect}, but #{fieldname} is not defined"
      elsif self.class.multivaluefield(fieldname) ?
              (iv.any? {|v| v === value}) :
              (value === iv)
        if @user and @dn
          if fieldname = self.class.fieldtoldap(fieldname)
            syntax = @user.attributemetadata[fieldname][:syntax]
            if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
              # DN
              if value.is_a? Net::LDAP::DN
                ops.push [:delete, fieldname, value]
              elsif value.dn
                ops.push [:delete, fieldname, value.dn]
              end
            elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
              # Integer
              ops.push [:delete, fieldname, value.to_s]
            elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
              # Boolean
              ops.push [:delete, fieldname, value.to_s.upcase]
            else
              ops.push [:delete, fieldname, value]
            end
          end
        end
      else
        raise "Trying to delete #{oldvalue.inspect} from #{fieldname} in #{self.inspect}, but #{fieldname} contains #{iv.inspect}"
      end
    end
    unless ops == []
      @user.modifyattributes @dn, ops
    end
  end
  
  def modifyinstancevariable(fieldname, oldvalue, newvalue)
    if self.class.multivaluefield(fieldname)
      if oldvalues = getinstancevariable(fieldname)
        instance_variable_set "@#{fieldname}".to_sym, oldvalues.delete_if {|i| i == oldvalue}
      end
    else
      instance_variable_set "@#{fieldname}".to_sym, nil
    end
  end

  def modifyfields(**options)
    ops = []
    options.each do |fieldname, valuepairs|
      valuepairs.each do |oldvalue, newvalue|
        iv = getinstancevariable(fieldname)
        if not iv
          raise "Trying to change #{fieldname} in #{self.inspect} from #{oldvalue.inspect} to #{newvalue.inspect}, but #{fieldname} is not defined"
        elsif self.class.multivaluefield(fieldname) ?
             (iv.any? {|value| value === oldvalue}) :
             (oldvalue === iv)
          unless newvalue.is_a? Net::LDAP::DN
            modifyinstancevariable fieldname, oldvalue, newvalue
          end
          if @user and @dn
            if fieldname = self.class.fieldtoldap(fieldname)
              syntax = @user.attributemetadata[fieldname][:syntax]
              if syntax == '1.3.6.1.4.1.1466.115.121.1.12'
                # DN
                if newvalue.is_a? Net::LDAP::DN
                  ops.push [:replace, fieldname, [oldvalue.dn, newvalue]]
                elsif newvalue.dn
                  ops.push [:replace, fieldname, [oldvalue.dn, newvalue.dn]]
                end
              elsif syntax == '1.3.6.1.4.1.1466.115.121.1.27'
                # Integer
                ops.push [:delete, fieldname, [oldvalue.to_s, newvalue.to_s]]
              elsif syntax == '1.3.6.1.4.1.1466.115.121.1.7'
                # Boolean
                ops.push [:delete, fieldname, [oldvalue.to_s.upcase, newvalue.to_s.upcase]]
              else
                ops.push [:delete, fieldname, [oldvalue, newvalue]]
              end
            end
          end
        else
          raise "Trying to change #{fieldname} in #{self.inspect} from #{oldvalue.inspect} to #{newvalue.inspect}, but #{fieldname} contains #{iv.inspect}"
        end
      end
    end
    unless ops == []
      @user.modifyattributes @dn, ops
    end
  end

  def superior
    if @superior
      @superior
    elsif dn
      superiordn = Net::LDAP::DN.new *((Net::LDAP::DN.new dn).to_a[2..999])
      @user.objectfromdn[superiordn]
    end
  end
end

class Head < Entry
  attr_gedcom :sources, :sour
  attr_reader :sources
  attr_reader :destination
  attr_reader :date
  attr_reader :subm
  attr_reader :file
  attr_reader :gedcom
  attr_reader :charset
  attr_gedcom :charset, :char

  def initialize(sources: nil, **options)
    if sources
      if sources.is_a? Array
        super(sources: sources, superior: sources[0], **options)
      else
        super(sources: [sources], superior: sources, **options)
      end
    else
      super(**options)
    end
  end
  
  def dn
    @superior.dn
  end
end

class Address < Entry
  attr_reader :address
  attr_reader :phones
  attr_multi :phon
  attr_gedcom :address, :addr
  attr_gedcom :continuation, :cont
  attr_multi :continuation

  def initialize(arg: "", **options)
    @phones = []
    super(address: arg, **options)
  end
  
  class << self
    def fieldnametoclass(fieldname)
      if fieldname == :continuation
        StringArgument
      else
        super
      end
    end
  end

  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :continuation
        @address += "\n" + value
        options.delete fieldname
      end
    end
    super(**options)
  end
end

class StringArgument < Entry
  def initialize(fieldname: "", arg: "", superior: nil, **options)
    iv = superior.getinstancevariable(fieldname)
    if superior.class.multivaluefield(fieldname) or superior.getinstancevariable('noldapobject') or (not iv) or (iv == "")
      superior.addfields(fieldname => arg)
    else
      raise "Trying to set #{fieldname.inspect} to #{arg}, but it is currently #{iv.inspect}"
    end
  end
end

class RoughDate < Entry
  attr_reader :relative
  attr_reader :year
  attr_reader :month
  attr_reader :day
  attr_reader :raw

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
  
  def initialize(arg: "", superior: nil, **options)
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
    
    superior.addfields(date: raw,
                     year: year,
                     month: month,
                     day: day,
                     relativetodate: relative,
                     baddata: baddata)
  end
end

class Place < Entry
  ldap_class :locality
  attr_reader :name
  attr_ldap :name, :l
  attr_reader :places
  attr_reader :events
  attr_gedcom :events, :even

  def initialize(ldapentry: nil, superior: nil, arg: "", user: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, user: user)
    else
      @user = user
      args = arg.split /\s*,\s*/
      dn = Net::LDAP::DN.new *(args.map {|i| ["l", i]}.flatten), basedn
      name = args[0]
      super(name: name, dn: dn, individual: superior, superior: superior, **options)
      makealias superior
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
      if key == "l"
        parts.push val
      end
    end
    parts.join(', ')
  end
end

class Event < Entry
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
  attr_ldap :source, :sourcedns
  attr_multi :tasks
  attr_ldap :tasks, :taskdns
  attr_multi :notes
  attr_gedcom :notes, :note

  class << self
    def fieldnametoclass(fieldname)
      if fieldname == :date
        RoughDate
      elsif fieldname == :place
        Place
      else
        super
      end
    end
  end

  def initialize(**options)
    @sources = []
    super(**options)
  end
  
  def === (foo)
    super || ((@year === foo.year) && (@month === foo.month) && (@day === foo.day) && (@relativetodate === foo.relativetodate) && (@place === foo.place))
  end
  
  def getnewrdn
    "#{description} #{date} #{place}".rstrip
  end
  
  def fixreferences(old, new)
    @sources.each do |source|
      source.object.updatedns old, new
    end
    super
  end

  def mergeinto(otherpage)
    puts "Merging #{dn}"
    puts "   into #{otherpage.dn}"
    fixreferences self, otherpage
    puts "    Deleting #{dn}"
    @user.ldap.delete dn: dn
    @user.objectfromdn.delete dn
  end
  
  def addfields(**options)
    unless @description
      if options[:date]
        if options[:place]
          options[:description] = "#{options[:place]} #{options[:date]}"
        else
          options[:description] = options[:date]
        end
      elsif options[:place]
        options[:description] = options[:place].to_s
      end
    end
    super(**options)
  end
  
  def to_s
    if date
      "#{@description} #{date} #{@place}"
    else
      "#{@description} ? #{@place}"
    end
  end

  def rdn
    @noldapobject = not(@description)
    [:description, @description]
  end
end

class IndividualEvent < Event
  ldap_class :gedcomindividualevent

  def individual
    if superior.is_a? IndividualEvent
      superior.individual
    else
      superior
    end
  end

  def to_s
    if date
      "#{@individual} #{@description} #{date} #{@place}"
    else
      "#{@individual} #{@description} ? #{@place}"
    end
  end

  def fixreferences(old, new)
    individual.updatedns old, new
    super
  end
end

class Birth < IndividualEvent
  ldap_class :gedcombirth

  def initialize(superior: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(superior: superior, description: "Birth of #{superior.fullname}", **options)
    end
  end
end

class Death < IndividualEvent
  ldap_class :gedcomdeath
  attr_gedcom :cause, :caus
  attr_ldap :cause, :cause

  def initialize(superior: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(superior: superior, description: "Death of #{superior.fullname}", **options)
    end
  end
end

class Burial < IndividualEvent
  ldap_class :gedcomburial
end

class CoupleEvent < Event
  ldap_class :gedcomcoupleevent
  attr_ldap :couple, :coupledns

  def initialize(superior: nil, ldapentry: nil, **options)
    @superiors = []
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      couple = []
      if superior.husband
        couple.push superior.husband
      end
      if superior.wife
        couple.push superior.wife
      end
      super(couple: couple, description: "#{self.class} of #{couple.map {|i| i.fullname}.join(' and ')}", **options)
      couple[1..999].each do |i|
        i.makealias self
      end
    end
  end

  def basedn
    @couple[0].dn
  end
end

class Marriage < CoupleEvent
  ldap_class :gedcommarriage
  attr_gedcom :officiator, :offi
  attr_ldap :officiator, :officiator

  class << self
    def fieldnametoclass(fieldname)
      if fieldname == :officiator
        Officiator
      else
        super
      end
    end
  end
end

class Divorce < CoupleEvent
  ldap_class :gedcomdivorce
end

class Adoption < IndividualEvent
  ldap_class :gedcomadoption
  attr_reader :parents
  attr_ldap :parents, :parentdns
  attr_multi :parentoffamily
  attr_gedcom :parentoffamily, :fams
  attr_gedcom :childoffamily, :famc

  class << self
    def fieldnametoclass(fieldname)
      if [:parentoffamily, :childoffamily].member? fieldname
        Family
      else
        super
      end
    end
  end
  
  def initialize(superior: nil, ldapentry: nil, **options)
    @parents = []
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(superior: superior, description: "Adoption of #{superior.fullname}", **options)
    end
  end

  def addfields(**options)
    options.each do |fieldname, value|
      if fieldname == :childoffamily
        value.addfields(events: self)
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
      if fieldname == :childoffamily
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

class Baptism < IndividualEvent
  ldap_class :gedcombaptism

  def initialize(superior: nil, ldapentry: nil, **options)
    if ldapentry
      super(ldapentry: ldapentry, **options)
    else
      super(superior: superior, description: "Baptism of #{superior.fullname}", **options)
    end
  end
end

class Individual < Entry
  ldap_class :gedcomindividual
  attr_gedcom :gender, :sex
  attr_gedcom :adoption, :adop
  attr_gedcom :baptism, :bapm
  attr_gedcom :events, :even
  attr_gedcom :birth, :birt
  attr_ldap :birth, :birthdn
  attr_reader :baptism
  attr_gedcom :burial, :buri
  attr_accessor :death
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
  attr_reader :fullname
  attr_ldap :fullname, :cn
  attr_ldap :first, :givenname
  attr_ldap :last, :sn
  attr_ldap :suffix, :initials
  attr_multi :tasks
  attr_ldap :tasks, :taskdns
  attr_multi :parentoffamily
  attr_gedcom :parentoffamily, :fams
  attr_gedcom :childoffamily, :famc
  attr_multi :notes
  attr_gedcom :notes, :note

  class << self
    def fieldnametoclass(fieldname)
      if [:auth, :cause, :corp, :file, :form, :phon, :publ, :title, :description, :version].member? fieldname
        StringArgument
      elsif [:parentoffamily, :childoffamily].member? fieldname
        Family
      elsif fieldname == :adoption
        Adoption
      elsif fieldname == :baptism
        Baptism
      elsif fieldname == :birth
        Birth
      elsif fieldname == :burial
        Burial
      elsif fieldname == :death
        Death
      elsif fieldname == :events
        IndividualEvent
      elsif fieldname == :names
        Name
      elsif fieldname == :gender
        Gender
      else
        super
      end
    end
  end
  
  def basedn
    Net::LDAP::DN.new "ou", "Individuals", @sources[0].dn
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
    @birth or Birth.new superior: self, fieldname: :birth, user: @user
  end
  
  def addfields(**options)
    newoptions = {}
    options.each do |fieldname, value|
      if fieldname == :names
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
      elsif fieldname == :events
        if value and not self == value.superior
          if value.dn
            makealias value
          else
            puts "#{fieldname.inspect} #{value.inspect} (being added to #{self.inspect}) doesn't have a dn"
          end
        end
        options.delete fieldname
      elsif fieldname == :mother
        value.addfields(events: self.birth)
      elsif fieldname == :father
        value.addfields(events: self.birth)
      elsif fieldname == :sources
        @user.findobjects('gedcomEvent', @dn) do |event|
          event.addfields(sources: value)
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
      if fieldname == :sources
        @user.findobjects('gedcomEvent', @dn) do |event|
          event.delfields(sources: value)
        end
      end
    end
    super(**options)
  end

  def updatedns(from, to)
    if @birth
      if from.dn.to_s === @birth.dn.to_s
        modifyfields(birth: {from => to})
      end
    end
    if @adoption
      if from.dn.to_s === @adoption.dn.to_s
        modifyfields(adoption: {from => to})
      end
    end
    if @baptism
      if from.dn.to_s === @baptism.dn.to_s
        modifyfields(baptism: {from => to})
      end
    end
    if @death
      if from.dn.to_s === @death.dn.to_s
        # Don't know why modifyfields doesn't work here!
        #modifyfields(death: {from => to})
        deletefields(death: from)
        addfields(death: to)
      end
    end
    if @burial
      if from.dn.to_s === @burial.dn.to_s
        modifyfields(burial: {from => to})
      end
    end
  end
end

class CharacterSet < Entry
  def initialize(fieldname: nil, arg: "", superior: nil, **options)
    if arg == 'ANSEL'
      superior.addfields(fieldname => ANSEL::Converter.new)
    else
      raise "Don't know what to do with #{arg} encoding"
    end
  end
end

class Officiator < Entry
  def initialize(arg: "", superior: nil, **options)
    (@first, @last, @suffix) = arg.split(/\s*\/[\s,]*/)
    puts "#{arg} officiated at #{superior.inspect}"
#    superior.addfields(fieldname, $names[@last][@first][@suffix]])
  end
end

class Name < Entry
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
      makealias superior, superior.label.to_s
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

class Gender < Entry
  def initialize(fieldname: nil, arg: "", superior: nil, **options)
    if /^m/i.match(arg)
      gender = :male
    elsif /^f/i.match(arg)
      gender = :female
    else
      gender = arg
    end
    superior.addfields(fieldname => gender)
  end
  
  def to_s
    @gender
  end
end

class Source < Entry
  ldap_class :gedcomsource
  attr_reader :version
  attr_gedcom :version, :vers
  attr_ldap :version, :version
  attr_reader :title
  attr_gedcom :title, :titl
  attr_ldap :title, :title
  attr_multi :notes
  attr_gedcom :notes, :note
  attr_reader :events
  attr_reader :corp
  attr_ldap :corp, :corp
  attr_reader :auth
  attr_ldap :auth, :author
  attr_reader :publ
  attr_ldap :publ, :publication
  attr_reader :filename
  attr_reader :head
  attr_reader :label
  attr_reader :references
  attr_ldap :references, :referencedns
  attr_ldap :rawdata, :rawdata
  attr_gedcom :sources, :sour
  attr_gedcom :pages, :page
  attr_multi :pages
  
  def initialize(arg: nil, filename: nil, **options)
    @authors = []
    @pages = []
    if filename
      super(filename: filename, title: File.basename(filename), rawdata: (File.read filename), **options)
      @user.makeou "Individuals", self.dn
      @user.makeou "Sources", self.dn
      ParseGedcomFile.new gedcomsource: self, user: @user
    else
      super(title: arg, **options)
    end
  end

  def basedn
    if @sources
      Net::LDAP::DN.new "ou", "Sources", @sources[0].dn
    else
      Net::LDAP::DN.new "ou", "Sources", @user.dn
    end
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
  
  def makeentry(label, fieldname, arg, superior)
    superiorclass = superior ? superior.class : self.class
    fieldname = superiorclass.gedcomtofield(fieldname) || fieldname
    classname = superiorclass.fieldnametoclass(fieldname)
    if matchdata = /^\@(?<ref>\w+)\@$/.match(arg)
      arg = matchdata[:ref].upcase.to_sym
      if @label[arg]
        @label[arg].superior = superior
        iv = superior.getinstancevariable(fieldname)
        unless (iv and iv.any? {|v| v === self})
          superior.addfields(fieldname => @label[arg])
        end
        obj = @label[arg]
      else
        obj = classname.new fieldname: fieldname, label: label, arg: arg, superior: superior, sources: self, user: @user
        @references[arg].push obj
      end
    else
      obj = classname.new fieldname: fieldname, label: label, arg: arg, superior: superior, sources: self, user: @user
    end
    obj
  end

  def parsefile
    entrystack = []
    @label = {:root => self}
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
        superior = entrystack[depth-1]
      else
        superior = nil
      end
      arg = matchdata[:arg] || ""
      entrystack[depth] = makeentry label, fieldname, arg, superior
    end
  end
  
  def to_s
    title
  end
end

class Note < Entry
  attr_reader :note
  attr_gedcom :continuation, :cont
  attr_multi :continuation

  def initialize(arg: "", **options)
    super(note: arg, **options)
  end

  class << self
    def fieldnametoclass(fieldname)
      if fieldname == :continuation
        StringArgument
      else
        super
      end
    end
  end

  def addfields(**options)
    puts options.inspect
    options.each do |fieldname, value|
      if fieldname == :continuation
        @note += "\n" + value
        options.delete fieldname
      end
    end
    puts options.inspect
    super(**options)
  end

  def to_s
    @title
  end
end

class Page < Entry
  ldap_class :sourcepage
  attr_reader :pageno
  attr_ldap :pageno, :description
  attr_reader :references
  attr_multi :references
  attr_ldap :references, :referencedns


  def initialize(arg: "", superior: nil, **options)
    if superior and superior.dn
      super(pageno: arg, sources: superior, superior: superior, references: superior.superior, **options)
      # Add us to the source's superior
      #source.superior.modifyfields(sources: {source => self})
      source.superior.addfields(sources: self)
    else
      super(arg: arg, **options)
    end
  end

  def === (foo)
    (self == foo) or super or (foo.is_a?(Page) and (@pageno === foo.pageno))
  end

  def fixreferences(old, new)
    references.each do |ref|
      ref.object.updatedns old, new
    end
  end
  
  def mergeinto(otherpage)
    puts "Merging #{dn}"
    puts "   into #{otherpage.dn}"
    fixreferences self, otherpage
    references.each do |ref|
     otherpage.addfields references: ref
    end
    puts "    Deleting #{dn}"
    @user.ldap.delete dn: dn
    @user.objectfromdn.delete dn
  end
  
  def source
    if superior.is_a? Page
      superior.source
    else
      superior
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

class Family < Entry
  attr_reader :husband
  attr_gedcom :husband, :husb
  attr_reader :wife
  attr_reader :events
  attr_multi :events
  attr_gedcom :events, :even
  attr_reader :children
  attr_gedcom :children, :chil
  attr_gedcom :marriage, :marr
  attr_gedcom :divorce, :div
  
  class << self
    def fieldnametoclass(fieldname)
      if fieldname == :divorce
        Divorce
      elsif fieldname == :events
        CoupleEvent
      elsif fieldname == :marriage
        Marriage
      else
        super
      end
    end
  end
  
  def initialize(**options)
    @events = []
    @children = []
    super(**options)
  end
  
  def === (foo)
    (arg and (arg === foo.arg)) && (super || ((@husband === foo.husband) && (@@wife === foo.wife) && (@@children === foo.children)))
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
      if fieldname == :husband
        @husband = value
        @children.each do |child|
          child.addfields(father: @husband)
        end
        @events.each do |event|
          @husband.addfields(events: event)
        end
        options.delete fieldname
      elsif fieldname == :wife
        @wife = value
        @children.each do |child|
          child.addfields(mother: @wife)
        end
        @events.each do |event|
          @wife.addfields(events: event)
        end
        options.delete fieldname
      elsif fieldname == :children
        @children.push value
        if @husband
          value.addfields(father: @husband)
        end
        if @wife
          value.addfields(mother: @wife)
        end
        options.delete fieldname
      elsif fieldname == :events
        if @husband
          @husband.addfields(events: value)
        end
        if @wife
          @wife.addfields(events: value)
        end
      end
    end
    super(**options)
  end

  def deletefields(**options)
    options.each do |fieldname, value|
      if fieldname == :events
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

class Task < Entry
  attr_ldap :uniqueidentifier, :uniqueidentifier

  @@counter = Time.new.to_i
  
  def basedn
    Net::LDAP::DN.new "ou", "Tasks", @user.basedn
  end
  
  def rdn
    @@counter += 1
    [:uniqueidentifier, "#{@user.username}-#{@@counter}"]
  end

  def runtask
    describeinfull
  end

  def deletefromtasklist
    @user.ldap.delete :dn => @dn
  end
end

class ConflictingEntries < Task
  ldap_class :conflictingevents
  attr_reader :baseentry
  attr_ldap :baseentry, :superiorentrydn

  def describeinfull
    puts "Conflicting entries (#{@uniqueidentifier})"
    event = @baseentry.object
    while event
      puts "    #{event.to_s}"
      event = @user.findobjects(event.class.classtoldapclass, event.dn)[0]
    end
  end

  def getleafandinternalnodes(baseentry)
    children = @user.findobjects(baseentry.class.classtoldapclass, baseentry.dn)
    if children == []
      return [[baseentry], []]
    else
      leaves = []
      internal = [baseentry]
      children.each do |child|
        (leaf, childinternal) = getleafandinternalnodes child
        leaves.push leaf
        internal.push childinternal
      end
      leaves.flatten!
      internal.flatten!
      return [leaves, internal]
    end
  end

  def runtask
    (leaves, internal) = getleafandinternalnodes @baseentry.object
    while internal != []
      done = leaves.any? do |leaf|
        internal.any? do |internal|
          if leaf === internal
            leaf.mergeinto internal
            true
          end
        end
      end
      if done
        (leaves, internal) = getleafandinternalnodes @baseentry.object
      else
        leaves.each do |leaf|
          leaf.renameandmoveto @baseentry.superior.dn
          done = true
        end
        if done
          (leaves, internal) = getleafandinternalnodes @baseentry.object
          if internal == []
            leaves.each do |leaf|
              leaf.renameandmoveto @baseentry.superior.dn
              done = true
            end
          end
        end
      end
    end
    deletefromtasklist
  end
  
  def to_s
    "Conflict at #{@baseentry}"
  end
end

class ErrorAddingField < Task
  ldap_class :erroraddingfield
  attr_reader :superiorentry
  attr_ldap :superiorentry, :superiorentrydn
  attr_ldap :fieldname, :fieldname
  attr_ldap :newvalue, :newentrydn

  def initialize(ldapentry: nil, **options)
    super(ldapentry: ldapentry, **options)
    unless ldapentry
      @superiorentry.addfields(tasks: self)
      @newvalue.addfields(tasks: self)
    end
  end

  def describeinfull
    puts "Error adding field (#{@uniqueidentifier})"
    puts "    #{@fieldname.to_sym.inspect} in #{@superiorentry}"
    puts "    first value: #{@superiorentry.send(@fieldname).dn}"
    puts "    second value: #{@newvalue.dn}"
  end
  
  def updatedns(from, to)
    if from.dn.to_s === @superiorentry.dn.to_s
      modifyfields(superiorentry: {from => to})
    end
    if from.dn.to_s === @newvalue.dn.to_s
      # Don't know why modifyfields doesn't work here!
      #modifyfields(newvalue: {from => to})
      deletefields(newvalue: from)
      addfields(newvalue: to)
    end
  end

  def to_s
    "Error adding #{fieldname.inspect} in #{superiorentry.dn}"
  end
end

class ParseGedcomFile < Task
  ldap_class :parsegedcomfile
  attr_ldap :gedcomsource, :superiorentrydn

  def describeinfull
    puts "Parse gedcom file (#{@uniqueidentifier})"
    puts "    Filename is #{@gedcomsource.title}"
  end

  def runtask
    deletefromtasklist
    @gedcomsource.parsefile
  end
  
  def to_s
    "Parse gedcom file #{@gedcomsource.title}"
  end
end

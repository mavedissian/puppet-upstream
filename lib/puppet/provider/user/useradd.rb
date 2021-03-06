require 'puppet/provider/nameservice/objectadd'
require 'date'

Puppet::Type.type(:user).provide :useradd, :parent => Puppet::Provider::NameService::ObjectAdd do
  desc "User management via `useradd` and its ilk.  Note that you will need to
    install Ruby's shadow password library (often known as `ruby-libshadow`)
    if you wish to manage user passwords."

  commands :add => "useradd", :delete => "userdel", :modify => "usermod", :password => "chage"

  options :home, :flag => "-d", :method => :dir
  options :comment, :method => :gecos
  options :groups, :flag => "-G"
  options :password_min_age, :flag => "-m", :method => :sp_min
  options :password_max_age, :flag => "-M", :method => :sp_max
  options :password, :method => :sp_pwdp
  options :expiry, :method => :sp_expire,
    :munge => proc { |value|
      if value == :absent
        ''
      else
        case Facter.value(:operatingsystem)
        when 'Solaris'
          # Solaris uses %m/%d/%Y for useradd/usermod
          expiry_year, expiry_month, expiry_day = value.split('-')
          [expiry_month, expiry_day, expiry_year].join('/')
        else
          value
        end
      end
    },
    :unmunge => proc { |value|
      if value == -1
        :absent
      else
        # Expiry is days after 1970-01-01
        (Date.new(1970,1,1) + value).strftime('%Y-%m-%d')
      end
    }

  verify :gid, "GID must be an integer" do |value|
    value.is_a? Integer
  end

  verify :groups, "Groups must be comma-separated" do |value|
    value !~ /\s/
  end

  has_features :manages_homedir, :allows_duplicates, :manages_expiry
  has_features :system_users unless %w{HP-UX Solaris}.include? Facter.value(:operatingsystem)

  has_features :manages_passwords, :manages_password_age if Puppet.features.libshadow?

  def check_allow_dup
    @resource.allowdupe? ? ["-o"] : []
  end

  def check_manage_home
    cmd = []
    if @resource.managehome?
      cmd << "-m"
    elsif Facter.value(:osfamily) == 'RedHat'
      cmd << "-M"
    end
    cmd
  end

  def check_system_users
    if self.class.system_users? and resource.system?
      ["-r"]
    else
      []
    end
  end

  def add_properties
    cmd = []
    # validproperties is a list of properties in undefined order
    # sort them to have a predictable command line in tests
    Puppet::Type.type(:user).validproperties.sort.each do |property|
      next if property == :ensure
      next if property.to_s =~ /password_.+_age/
      # the value needs to be quoted, mostly because -c might
      # have spaces in it
      if value = @resource.should(property) and value != ""
        cmd << flag(property) << munge(property, value)
      end
    end
    cmd
  end

  def addcmd
    cmd = [command(:add)]
    cmd += add_properties
    cmd += check_allow_dup
    cmd += check_manage_home
    cmd += check_system_users
    cmd << @resource[:name]
  end

  def deletecmd
    cmd = [command(:delete)]
    cmd += @resource.managehome? ? ['-r'] : []
    cmd << @resource[:name]
  end

  def passcmd
    age_limits = [:password_min_age, :password_max_age].select { |property| @resource.should(property) }
    if age_limits.empty?
      nil
    else
      [command(:password),age_limits.collect { |property| [flag(property), @resource.should(property)]}, @resource[:name]].flatten
    end
  end

  [:expiry, :password_min_age, :password_max_age, :password].each do |shadow_property|
    define_method(shadow_property) do
      if Puppet.features.libshadow?
        if ent = Shadow::Passwd.getspnam(@resource.name)
          method = self.class.option(shadow_property, :method)
          return unmunge(shadow_property, ent.send(method))
        end
      end
      :absent
    end
  end
end

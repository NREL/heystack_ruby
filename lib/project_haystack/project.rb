module ProjectHaystack
  require 'json'
  require 'pp'
  # may consider making this a mixin instead
  class Project
    
    attr_accessor :name, :haystack_version, :base_url #required
    def initialize(name, config)
      puts "initializing haystack #{name}"
      @name = name
      @base_url = config['base_url']
      @haystack_version = config['haystack_version']
      @secure = config['secure']
      # expect to use basic auth
      if config['credentials'].present?
        @credentials = config['credentials']
       #for now at least, we fake the user object
      #expect to use scram
      else
        user = OpenStruct.new
        user.username = config['username']
        user.password = config['password']

        # TODO load auth token from a user database and only initiate scram conversation if necessary
        auth_conv = ProjectHaystack::Auth::Scram::Conversation.new(user)
        puts "starting auth conv"
        auth_conv.authorize
        puts "after authorize"
        @auth_token = auth_conv.auth_token
      end
      puts "after initializing #{self.inspect}"
    end
    # for now, setting up to have a single connection per project 
    def connection
      url = (@secure) ? 'https://' : 'http://'
      url = "#{url}#{@base_url}"
      @connection ||= Faraday.new(:url => url) do |faraday|
        faraday.request  :url_encoded             # form-encode POST params
        faraday.response :logger                  # log requests to STDOUT
        faraday.adapter  Faraday.default_adapter  # make requests with Net::HTTP
        faraday.headers['Authorization'] = @auth_token.present? ? "BEARER authToken=#{@auth_token}" : "Basic #@credentials"
        faraday.headers['Accept'] = 'application/json' #TODO enable more formats
      end
    end

    def read(params)
      body = ["ver:\"#{@haystack_version}\""]
      body << params.keys.join(',')
      body << params.values.join(',')
      res = self.connection.post('read') do |req|
        req.headers['Content-Type'] = 'text/plain'
        req.body = body.join("\n")
      end
      JSON.parse! res.body
    end

    # return meta data for all equip with related points
    def equip_point_meta
      # begin
        equips = read({filter: '"equip"'})['rows']
        puts equips
        equips.map! do |eq|
          eq.delete('disMacro')
          eq['description'] = eq['id'].match(/[(NWTC)|(\$siteRef)] (.*)/)[1]
          eq['id'] = eq['id'].match(/:([a-z0-9\-]*)/)[1]
          eq['points'] = []
          read({filter: "\"point and equipRef==#{eq['id']}\""})['rows'].each do |p|
            p.delete('analytics')
            p.delete('disMacro')
            p.delete('csvUnit')
            p.delete('csvColumn')
            p.delete('equipRef')
            p.delete('point')
            p.delete('siteRef')

            p['id'] = p['id'].match(/:([a-z0-9\-]*)/)[1]
            p['name'] = p['navName']
            p.delete('navName')
            eq['points'] << p
          end
          eq
        end
      # rescue Exception => e
        puts "error: #{e}"
        nil
      # end
    end

    def ops
      JSON.parse!(self.connection.get("ops").body)['rows']
    end

    def valid?
      !(@name.nil? || @haystack_version.nil? || @base_url.nil?)
    end

    # http://www.skyfoundry.com/doc/docSkySpark/Ops#commit
    # grid is array of strings
    def commit grid
      puts 'grid = '
      pp grid.join "\n"
      res = self.connection.post('commit') do |req|
        req.headers['Content-Type'] = 'text/plain'
        req.body = grid.join "\n"
      end
      JSON.parse! res.body
    end

    # params is array of hashes: {name: xx, type: xx, value: xx}
    def add_rec params
      grid = ["ver:\"#{@haystack_version}\" commit:\"add\""]
      grid << params.map{|p| p[:name]}.join(',')
      values = params.map do |p|
        p[:value] = "\"#{p[:value]}\"" if p[:type] == 'String'
        p[:value]
      end
      grid << values.join(',')
      res = commit grid 
      # return id of new rec
      res['rows'][0]['id']     
    end

# TODO fix these.  weird sensitivities around mod timestamp (format and time)
    # params is array of hashes: {name: xx, type: xx, value: xx}
    def update_rec id,params
      grid = ["ver:\"#{@haystack_version}\" commit:\"update\""]
      grid << 'id,mod,' + params.map{|p| p[:name]}.join(',')
      values = params.map do |p|
        p[:value] = "\"#{p[:value]}\"" if p[:type] == 'String'
        p[:value]
      end
      grid << "#{id},#{DateTime.now},#{values.join(',')}"
      commit grid      
    end

    def remove_rec id
      grid = ["ver:\"#{@haystack_version}\" commit:\"remove\""]
      grid << 'id,mod' 
      grid << "#{id},#{DateTime.now}"
      commit grid      
    end
  end
end
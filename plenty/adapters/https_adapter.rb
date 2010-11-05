module Plenty::Adapters
  class HttpsAdapter
    def self.generate_token(command)
      t = Time.now
      d = Digest::MD5.new
      token = d.hexdigest("#{Plenty.configuration.api_token}#{t.strftime("%Y%m%d")}#{command}")
    end
    
    def self.call(command = 'ArticleBasicXML', opts = {})
      token = self.generate_token(command)    
      page              = opts[:page] || 1
      additional_params = opts[:additional_params] || ""
      additional_params = "&#{additional_params}" if opts[:additional_params]


      http = Net::HTTP.new(Plenty.configuration.host, 443)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE

      path = "/plenty/api/external.php?PlentyAPIToken=#{token}&format=#{command}&Page=#{page}#{additional_params}"
      url = "#{Plenty.configuration.host}#{path}"
      puts url

      resp, data = http.get(path, nil)
      Nokogiri::XML.parse(data)
    end
    
    def self.post(command = 'StockXML', opts = {})
      token = self.generate_token(command)    
      page              = opts[:page] || 1
      additional_params = opts[:additional_params] || ""
      additional_params = "&#{additional_params}" if opts[:additional_params]

      path = "/plenty/api/external_writer.php?PlentyAPIToken=#{token}&format=#{command}&params[Data]=#{URI.escape(opts[:data])}"
      url = "#{Plenty.configuration.host}#{path}"
      request = Net::HTTP::Post.new(path)

      puts path

      http = Net::HTTP.new(Plenty.configuration.host, 443)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      data = http.start {|http_block| http_block.request(request) }

      data.body
    end
  end
end
require 'net/smtp'
require 'openssl'

module Uhuru::BoshCommander
  class AppcloudngField < Field

    def initialize(name, screen, form)
      super(name, screen, form)
    end

    private

    def validate_value(value_type)
      if value_type == GenericForm::VALUE_TYPE_FORM
        return ''
      end

      error = ''
      value = get_value value_type
      deployment = @form.get_data value_type

      if @screen.name == 'Network'
        if @name == 'static_ip_range'
          static_ip_needed = deployment["jobs"].select{|job| job["networks"][0].has_key?("static_ips")}.inject(0){|sum, job| sum += job["instances"].to_i}
          static_ips_provided = IPHelper.ip_count_in_range(value)
          if static_ips_provided < static_ip_needed
            error = "Not enough static IPs! provided: #{static_ips_provided} needed: #{static_ip_needed}"
          end
        elsif @name == 'dynamic_ip_range'
          dynamic_ip_needed = 2 * deployment["jobs"].inject(0){|sum, job| sum += job["instances"].to_i}
          dynamic_ips_provided = IPHelper.ip_count_in_range(value)
          if dynamic_ips_provided < dynamic_ip_needed
            error = "Not enough dynamic IPs! provided: #{dynamic_ips_provided} needed: #{dynamic_ip_needed}"
          end
        end
      elsif @screen.name == 'Resource Pools'
        if [ 'linux_stemcell', 'windows_stemcell', 'sqlserver_stemcell'].include? @name
          if value == "name:,version:"
            if @name == "windows_stemcell"
              if (deployment['resource_pools'].select{|pool| pool["name"] == "windows"}.first["size"] != 0)
                error = "Invalid stemcell"
              end
            elsif @name == "sqlserver_stemcell"
              if (deployment['resource_pools'].select{|pool| pool["name"] == "sqlserver"}.first["size"] != 0)
                error = "Invalid stemcell"
              end
            else
              error = "Invalid stemcell"
            end
          end         
        end
      elsif @screen.name == 'Properties'
        if @name == 'app_domains'
          app_domains = value.gsub(/,/, ';').split(';').map(&:strip).reject(&:empty?)
          if app_domains.include?(deployment['properties']['domain'])
            error = 'The list of application domains cannot include the system domain of the cloud.'
          end
        elsif @name == 'admin_password'
          unless value.to_s.match(/(?=^.{6,20}$)((?=.*\d)(?=.*[A-Z])(?=.*[a-z])|(?=.*\d)(?=.*[^A-Za-z0-9])(?=.*[a-z])|(?=.*[^A-Za-z0-9])(?=.*[A-Z])(?=.*[a-z])|(?=.*\d)(?=.*[A-Z])(?=.*[^A-Za-z0-9]))^.*/)
            error = 'Provided password does not meet the length or complexity requirements'
          end
        end
      end
      error
    end

    # This method is called when we want to show values on the form
    def get_exotic_value(value, value_type)
      def handle_exotic_type(value)
        data_type = get_data_type
        result = nil

        if data_type == TYPE_CSV || data_type == TYPE_IP_LIST
          result = value.join(';')
        elsif data_type == TYPE_IP_RANGE
          ip_ranges = value.map do |range|
            range.split('-').map(&:strip).reject(&:empty?)
          end
          result = IPHelper.to_string ip_ranges
        end

        result
      end

      result = nil
      begin
        if @screen.name == 'Network'
          if @name == 'dynamic_ip_range'
            deployment = @form.get_data value_type

            range = deployment["networks"][0]["subnets"][0]["range"]
            gateway = deployment["networks"][0]["subnets"][0]["gateway"]
            static_ips = deployment["networks"][0]["subnets"][0]["static"]

            if gateway == nil || gateway.strip == ''
              gateway = '0.0.0.0'
            end

            gateway.strip!
            range = [IPHelper.get_subnet_limits(range)]
            range = IPHelper.subtract_range(range, [gateway, gateway])

            static_ips.each do |static_range|
              range = IPHelper.subtract_range(range, static_range.split('-').map(&:strip).reject(&:empty?))
            end

            value.each do |reserved_range|
              range = IPHelper.subtract_range(range, reserved_range.split('-').map(&:strip).reject(&:empty?))
            end

            result = IPHelper.to_string range
          elsif @name == 'subnet_mask'
            result = IPHelper.get_subnet_netmask(value)
          end
        elsif @screen.name == 'Properties'
          if @name == 'admin_email'
            result = value.split('|')[0]
          end
        elsif @screen.name == 'Resource Pools'
          if [ 'linux_stemcell', 'windows_stemcell'].include? @name
            result = "name:#{value["name"]},version:#{value["version"]}"
          end
        end

        if result == nil
          result = handle_exotic_type(value)
        end
      rescue => e
        $logger.warn "Could not generate exotic value for '#{html_form_id}' - #{e.message} : #{e.backtrace}"
        result = ''
      end

      result
    end

    # This method is called when we want to save data. This is where we have to manipulate values before we save them.
    def generate_exotic_value(value)
      def handle_exotic_type(value)
        data_type = get_data_type
        result = nil

        if data_type == TYPE_CSV || data_type == TYPE_IP_LIST
          result = value.gsub(/,/, ';').split(';').map(&:strip).reject(&:empty?)
        elsif data_type == TYPE_IP_RANGE
          result = IPHelper.from_string(value).map do |range|
            "#{range[0]}-#{range[1]}"
          end
        end

        result
      end

      result = nil
      if @screen.name == 'Network'
        if @name == 'dynamic_ip_range'
          form_data = @form.get_data GenericForm::VALUE_TYPE_FORM
          gateway = form_data['appcloudng:Network:gateway']
          subnet_short = IPHelper.get_subnet_short(form_data['appcloudng:Network:subnet_mask'])
          static_ips = IPHelper.from_string(form_data['appcloudng:Network:static_ip_range'])
          dynamic_ips = IPHelper.from_string(form_data['appcloudng:Network:dynamic_ip_range'])
          result_range = [IPHelper.get_subnet_limits("#{gateway}/#{subnet_short}")]
          result_range = IPHelper.subtract_range(result_range, [gateway, gateway])
          static_ips.each do |static_range|
            result_range = IPHelper.subtract_range(result_range, static_range)
          end
          dynamic_ips.each do |dynamic_range|
            result_range = IPHelper.subtract_range(result_range, dynamic_range)
          end
          result = result_range.map do |range|
            "#{range[0]}-#{range[1]}"
          end
        elsif @name == 'subnet_mask'
          form_data = @form.get_data GenericForm::VALUE_TYPE_FORM
          subnet_short = IPHelper.get_subnet_short(value)
          range = IPHelper.get_subnet_limits("#{form_data['appcloudng:Network:gateway']}/#{subnet_short}")
          range = IPHelper.ip_to_string(IPHelper.ip_to_int(range[0]) - 1)
          result = "#{range}/#{subnet_short}"
        end
      elsif @screen.name == 'Properties'
        if @name == 'domain'
          result = value.to_s.downcase
        elsif @name == 'admin_email'
          form_data = @form.get_data GenericForm::VALUE_TYPE_FORM
          result = "#{value}|#{form_data['appcloudng:Properties:admin_password']}|scim.write,scim.read,openid,cloud_controller.admin"
        end
      elsif @screen.name == 'Resource Pools'
        if [ 'linux_stemcell', 'windows_stemcell' ].include? @name
          if (value != "")
            name = value.match(/name:([^\/]*),version/)[1]
            version = value.match(/version:([^\/]*)\z/)[1]
            result = { "name" => name, "version" => version }
          else
            result = { "name" => "", "version" => "" }
          end
        end
      end

      if result == nil
        result = handle_exotic_type(value)
      end

      result
    end

  end
end

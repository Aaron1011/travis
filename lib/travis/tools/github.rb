require 'travis/tools/system'
require 'yaml'
require 'json'

module Travis
  module Tools
    class Github
      TOKEN_SIZE  = 40
      GITHUB_API  = 'api.github.com'
      GITHUB_HOST = 'github.com'

      attr_accessor :api_url, :scopes, :github_token, :github_login, :drop_token, :callback, :explode, :after_tokens,
        :ask_login, :ask_password, :ask_otp, :login_header, :auto_token, :auto_password, :manual_login, :note,
        :netrc_path, :hub_path, :oauth_paths, :composer_path, :git_config_keys, :debug, :no_token, :check_token

      def initialize(options = nil)
        @check_token     = true
        @manual_login    = true
        @ask_login       = proc { raise "ask_login callback not set" }
        @after_tokens    = proc { }
        @ask_password    = proc { |_| raise "ask_password callback not set" }
        @ask_otp         = proc { |_| raise "ask_otp callback not set" }
        @debug           = proc { |_| }
        @netrc_path      = '~/.netrc'
        @hub_path        = ENV['HUB_CONFIG'] || '~/.config/hub'
        @oauth_paths     = ['~/.github-oauth-token']
        @composer_path   = "~/.composer/config.json"
        @note            = 'temporary token'
        @git_config_keys = %w[github.token github.oauth-token]
        @scopes          = ['user', 'user:email', 'repo'] # overridden by value from /config
        options.each_pair { |k,v| send("#{k}=", v) if respond_to? "#{k}=" } if options
        yield self if block_given?
      end

      def with_token
        each_token { |t| break yield(t) }
      end

      def each_token
        require 'gh' unless defined? GH
        possible_tokens { |t| yield(t) if acceptable?(t) }
      ensure
        callback, self.callback = self.callback, nil
        callback.call if callback
      end

      def with_session(&block)
        with_token { |t| GH.with(:token => t, &block) }
      end

      def possible_tokens(&block)
        return block[github_token] if github_token

        if auto_token
          netrc_tokens(&block)
          git_tokens(&block)
          hub_tokens(&block)
          oauth_file_tokens(&block)
          github_for_mac_token(&block)
          issuepost_token(&block)
          composer_token(&block)
        end

        if auto_password
          possible_logins do |user, password|
            yield login(user, password, false)
          end
        end

        if manual_login
          login_header.call if login_header
          user     = github_login || ask_login.call
          password = ask_password.call(user)
          yield login(user, password, true)
        end

        after_tokens.call
      end

      def possible_logins(&block)
        netrc_logins(&block)
        hub_logins(&block)
        keychain_login(&block)
      end

      def netrc_tokens
        netrc.each do |entry|
          next unless entry["machine"] == api_host or entry["machine"] == host
          entry.values_at("token", "login", "password").each do |entry|
            next if entry.to_s.size != TOKEN_SIZE
            debug "found oauth token in netrc"
            yield entry
          end
        end
      end

      def git_tokens
        return unless System.has? 'git'
        git_config_keys.each do |key|
          `git config --get-all #{key}`.each_line do |line|
            token = line.strip
            yield token unless token.empty?
          end
        end
      end

      def composer_token
        file(composer_path) do |content|
          token = JSON.parse(content)['config'].fetch('github-oauth', {})[host]
          yield token if token
        end
      end

      def hub_tokens
        hub.fetch(host, []).each do |entry|
          next if github_login and github_login != entry["user"]
          yield entry["oauth_token"] if entry["oauth_token"]
        end
      end

      def oauth_file_tokens(&block)
        oauth_paths.each do |path|
          file(path) do |content|
            token = content.strip
            yield token unless token.empty?
          end
        end
      end

      def netrc_logins
        netrc.each do |entry|
          next unless entry["machine"] == api_host or entry["machine"] == host
          next if github_login and github_login != entry["login"]
          yield entry["login"], entry["password"] if entry["login"] and entry["password"]
        end
      end

      def hub_logins
        hub.fetch(host, []).each do |entry|
          next if github_login and github_login != entry["user"]
          yield entry["user"], entry["password"] if entry["user"] and entry["password"]
        end
      end

      def keychain_login
        if github_login
          security(:internet, :w, "-s #{host} -a #{github_login}", "#{host} password for #{github_login}") do |password|
            yield github_login, password if password and not password.empty?
          end
        else
          security(:internet, :g, "-s #{host}", "#{host} login and password") do |data|
            username = data[/^\s+"acct"<blob>="(.*)"$/, 1].to_s
            password = data[/^password: "(.*)"$/, 1].to_s
            yield username, password unless username.empty? or password.empty?
          end
        end
      end

      def netrc
        file(netrc_path, []) do |contents|
          contents.scan(/^\s*(\S+)\s+(\S+)\s*$/).inject([]) do |mapping, (key, value)|
            mapping << {} if key == "machine"
            mapping.last[key] = value if mapping.last
            mapping
          end
        end
      end

      def hub
        file(hub_path, {}) do |contents|
          YAML.load(contents)
        end
      end

      def issuepost_token(&block)
        security(:generic, :w, "-l issuepost.github.access_token",  "issuepost token", &block) if host == 'github.com'
      end

      def github_for_mac_token(&block)
        command = '-s "github.com/mac"'
        command << " -a #{github_login}" if github_login
        security(:internet, :w, command, "GitHub for Mac token", &block) if host == 'github.com'
      end

      def host
        api_host == GITHUB_API ? GITHUB_HOST : api_host
      end

      def api_host
        return GITHUB_API unless api_url
        api_url[%r{^(?:https?://)?([^/]+)}, 1]
      end

      def login(user, password, die = true, otp = nil)
        opt           = { :username => user, :password => password }
        opt[:headers] = { "X-GitHub-OTP" => otp } if otp
        gh            = GH.with(opt)
        reply         = gh.post('/authorizations', :scopes => scopes, :note => note)
        self.callback = proc { gh.delete reply['_links']['self']['href'] }
        reply['token']
      rescue GH::Error => error
        if error.info[:response_status] == 401
          login(user, password, die, ask_otp.call(user))
        elsif die
          raise gh_error(error)
        end
      end

      def acceptable?(token)
        return true unless check_token
        gh   = GH.with(:token => token)
        user = gh['user']

        if github_login and github_login != user['login']
          debug "token is not acceptable: identifies %p instead of %p" % [user['login'], github_login]
          false
        else
          true
        end
      rescue GH::Error => error
        debug "token is not acceptable: #{gh_error(error)}"
        false
      end

      private

        def gh_error(error)
          raise error if explode
          JSON.parse(error.info[:response_body])["message"].to_s
        end

        def debug(line)
          return unless @debug
          @debug.call "Tools::Github: #{line}"
        end

        def security(type, key, arg, name)
          return false unless System.has? 'security'
          return false unless system "security find-#{type}-password #{arg} 2>/dev/null >/dev/null"
          debug "requesting to load #{name} from keychain"
          result = %x[security find-#{type}-password #{arg} -#{key} 2>&1].chomp
          $?.success? ? yield(result) : debug("request denied")
        rescue => e
          raise e if explode
        end

        def file(path, default = nil)
          path        &&= File.expand_path(path)
          @file       ||= {}
          @file[path] ||= if path and File.readable?(path)
            debug "reading #{path}"
            yield File.read(path)
          end
          @file[path] || default
        rescue => e
          raise e if explode
        end
    end
  end
end

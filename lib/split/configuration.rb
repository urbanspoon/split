module Split
  class Configuration
    attr_accessor :bots
    attr_accessor :robot_regex
    attr_accessor :ignore_ip_addresses
    attr_accessor :ignore_filter
    attr_accessor :db_failover
    attr_accessor :db_failover_on_db_error
    attr_accessor :db_failover_allow_parameter_override
    attr_accessor :allow_multiple_experiments
    attr_accessor :enabled
    attr_accessor :persistence
    attr_accessor :algorithm
    attr_accessor :store_override
    attr_accessor :on_trial_choose
    attr_accessor :on_trial_complete

    attr_reader :experiments

    def bots
      @bots ||= {
        # Indexers
        "AdsBot-Google" => 'Google Adwords',
        'Baidu' => 'Chinese search engine',
        'Gigabot' => 'Gigabot spider',
        'Googlebot' => 'Google spider',
        'msnbot' => 'Microsoft bot',
        'bingbot' => 'Microsoft bing bot',
        'rogerbot' => 'SeoMoz spider',
        'Slurp' => 'Yahoo spider',
        'Sogou' => 'Chinese search engine',
        "spider" => 'generic web spider',
        'WordPress' => 'WordPress spider',
        'ZIBB' => 'ZIBB spider',
        'YandexBot' => 'Yandex spider',
        # HTTP libraries
        'Apache-HttpClient' => 'Java http library',
        'AppEngine-Google' => 'Google App Engine',
        "curl" => 'curl unix CLI http client',
        'ColdFusion' => 'ColdFusion http library',
        "EventMachine HttpClient" => 'Ruby http library',
        "Go http package" => 'Go http library',
        'Java' => 'Generic Java http library',
        'libwww-perl' => 'Perl client-server library loved by script kids',
        'lwp-trivial' => 'Another Perl library loved by script kids',
        "Python-urllib" => 'Python http library',
        "PycURL" => 'Python http library',
        "Test Certificate Info" => 'C http library?',
        "Wget" => 'wget unix CLI http client',
        # URL expanders / previewers
        'awe.sm' => 'Awe.sm URL expander',
        "bitlybot" => 'bit.ly bot',
        "facebookexternalhit" => 'facebook bot',
        'LongURL' => 'URL expander service',
        'Twitterbot' => 'Twitter URL expander',
        'UnwindFetch' => 'Gnip URL expander',
        # Uptime monitoring
        'check_http' => 'Nagios monitor',
        'NewRelicPinger' => 'NewRelic monitor',
        'Panopta' => 'Monitoring service',
        "Pingdom" => 'Pingdom monitoring',
        'SiteUptime' => 'Site monitoring services',
        # ???
        "DigitalPersona Fingerprint Software" => 'HP Fingerprint scanner',
        "ShowyouBot" => 'Showyou iOS app spider',
        'ZyBorg' => 'Zyborg? Hmmm....',
      }
    end

    def experiments=(experiments)
      raise InvalidExperimentsFormatError.new('Experiments must be a Hash') unless experiments.respond_to?(:keys)

      @experiments = stringify_keys(experiments)
      persist(normalized_experiments)
      @metrics = nil
    end

    def stringify_keys(hash)
      stringified = {}
      hash.each_pair do |key, value|
        stringified[key.to_s] = value
      end
      stringified
    end

    def disabled?
      !enabled
    end

    def uncache(name)
      @experiments.delete(name)
      @experiment_config = nil
      @metrics = nil
      @versions = nil
    end

    def experiment_for(name)
      load_experiment(name)
      if normalized_experiments
        # TODO symbols
        normalized_experiments[name.to_s]
      end
    end

    def metrics
      return @metrics unless @metrics.nil?
      @metrics = {}
      if self.experiments
        self.experiments.each do |key, value|
          metric = value_for(value, :metric)
          unless metric.nil?
            metric_name = metric.to_s
            @metrics[metric_name] ||= []
            @metrics[metric_name] << Split::Experiment.new(key)
          end
        end
      end
      @metrics
    end

    def normalized_experiments
      return @experiment_config if @experiment_config
      if @experiments.nil? || @experiments.empty?
        {}
      else
        @experiment_config = {}
        @experiments.each do |name, settings|
          name = name.to_s
          @experiment_config[name] = {}
          if alternatives = value_for(settings, :alternatives)
            @experiment_config[name][:alternatives] = normalize_alternatives(alternatives)
          end
          [:goals, :metric, :resettable, :algorithm].each do |key|
            @experiment_config[name].merge! key_pair_for(settings, key)
          end
        end

        @experiment_config
      end
    end

    def normalize_alternatives(alternatives)
      given_probability, num_with_probability = alternatives.inject([0,0]) do |a,v|
        p, n = a
        if percent = value_for(v, :percent)
          [p + percent, n + 1]
        else
          a
        end
      end

      num_without_probability = alternatives.length - num_with_probability
      unassigned_probability = ((100.0 - given_probability) / num_without_probability)

      alternatives = alternatives.map do |v|
        if (name = value_for(v, :name)) && (percent = value_for(v, :percent))
          { name => percent }
        elsif name = value_for(v, :name)
          { name => unassigned_probability }
        else
          { v => unassigned_probability }
        end
      end

      [alternatives.shift, alternatives]
    end

    def robot_regex
      @robot_regex ||= /\b(?:#{escaped_bots.join('|')})\b|\A\W*\z/i
    end

    def initialize
      @ignore_ip_addresses = []
      @ignore_filter = proc{ |request| is_robot? || is_ignored_ip_address? }
      @db_failover = false
      @db_failover_on_db_error = proc{|error|} # e.g. use Rails logger here
      @db_failover_allow_parameter_override = false
      @allow_multiple_experiments = false
      @enabled = true
      @experiments = {}
      @persistence = Split::Persistence::SessionAdapter
      @algorithm = Split::Algorithms::WeightedSample

      @reload_period = 'versioned'
      @_last_reload = Time.new(0)
      @_cached_version = 0
    end

    def experiment_versions
      @versions ||= load_versions_from_redis
    end

    def increment_experiment_version(experiment_name)
      experiment_versions[experiment_name] = Split.redis.hincrby('versions', experiment_name, 1)
      increment_version
      experiment_versions[experiment_name]
    end

    def winner(experiment_name)
      @winners ||= load_winners
      @winners[experiment_name.to_s]
    end

    def set_winner(experiment_name, winner_name)
      Split.redis.hset(:experiment_winner, experiment_name, winner_name.to_s)
      @winners[experiment_name] = winner_name.to_s if @winners
      increment_version
    end

    def reset_winner(experiment_name)
      Split.redis.hdel(:experiment_winner, experiment_name)
      @winners[experiment_name] = nil if @winners
      increment_version
    end

    def update
      update_from_redis if enabled && time_to_reload?
    rescue => e
      raise unless db_failover
      db_failover_on_db_error.call(e)
    ensure
      return self
    end

    private

    def persist(experiments)
      experiments.each do |exp|
        name, options = exp
        normalized = Experiment.new(name, options)
        known = Experiment.find(name)
        unless known && known.to_hash == normalized.to_hash
          normalized.unpersist
          normalized.persist
          @experiments.merge! normalized.to_hash
        end
      end
    rescue => e
      raise unless db_failover
      db_failover_on_db_error.call(e)
    end

    def load_experiment(name)
      @experiments ||= {}
      return @experiments[name.to_s] if @experiments[name.to_s]

      e =  Experiment.from_redis(name)
      if e
        uncache(name)
        @experiments.merge!(e.to_hash)
      end
    end

    def time_to_reload?
      if @reload_period.to_s == 'versioned'
# @remote_version instance variable?
        @remote_version = config_version
        @remote_version.to_i > @_cached_version.to_i
      else
        @reload_period.to_i > 10 && (Time.now - @_last_reload > @reload_period)
      end
    rescue => e
      raise unless db_failover
      db_failover_on_db_error.call(e)
      return false
    end

    def update_from_redis
      last_reload = Time.now

      @versions = load_versions_from_redis
      @winners = load_winners

      @_last_reload = last_reload
      @_cached_version = @remote_version
      @remote_version = nil
    end

    def value_for(hash, key)
      if hash.kind_of?(Hash)
        value = hash[key.to_s]
        value.nil? ? hash[key.to_sym] : value
      end
    end

    def key_pair_for(hash,key)
      value = value_for(hash, key)
      value.nil? ? {} : {key => value}
    end

    def escaped_bots
      bots.map { |key, _| Regexp.escape(key) }
    end

    def load_winners
      Split.redis.hgetall(:experiment_winner)
    end

    def config_version
      Split.redis.get('config_version')
    end

    def increment_version
      Split.redis.incr('config_version')
    end

    def load_versions_from_redis
      Split.redis.hgetall('versions')
    end
  end
end

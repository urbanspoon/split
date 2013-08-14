module Split
  class Experiment
    attr_accessor :name
    attr_writer :algorithm
    attr_accessor :resettable
    attr_accessor :goals
    attr_accessor :alternatives
    attr_accessor :metric

    def initialize(name, options = {})
      options = {
        :resettable => true,
      }.merge(options)

      @name = name.to_s

      alts = options[:alternatives] || []

      if alts.length == 1
        if alts[0].is_a? Hash
          alts = alts[0].map{|k,v| {k => v} }
        end
      end

      if alts.empty?
        exp_config = Split.configuration.experiment_for(@name)
        if exp_config
          alts = load_alternatives_from_configuration
          options[:goals] = exp_config[:goals].flatten if exp_config[:goals]
          options[:resettable] = exp_config[:resettable]
          options[:algorithm] = exp_config[:algorithm]
        end
      end

      self.alternatives = alts.flatten
      self.goals = options[:goals] || []
      self.metric = options[:metric]
      self.algorithm = options[:algorithm]
      self.resettable = options[:resettable]
    end

    def self.names
      Split.redis.smembers(:experiments)
    end

    def self.all
      names.map {|e| find(e)}
    end

    def self.find(name)
      if Split.redis.exists(name)
        obj = self.new name
        obj.load_from_redis
      else
        obj = nil
      end
      obj
    end

    def self.find_or_create(label, *alternatives)
      experiment_name_with_version, goals = normalize_experiment(label)
      name = experiment_name_with_version.to_s.split(':')[0]

      exp = self.new name, :alternatives => alternatives, :goals => goals
      exp.save
      exp
    end

    def save
      validate!

      if new_record? # exists
        persist
      elsif new_version?
        unpersist
        persist
      end

      self
    end

    def validate!
      if @alternatives.empty? && Split.configuration.experiment_for(@name).nil?
        raise ExperimentNotFound.new("Experiment #{@name} not found")
      end
      @alternatives.each {|a| a.validate! }
      unless @goals.nil? || goals.kind_of?(Array)
        raise ArgumentError, 'Goals must be an array'
      end
    end

    def unpersist
      reset
      delete_goals
      delete_alternatives
    end

    def persist
      Split.redis.sadd(:experiments, name)
      Split.redis.hset(:experiment_start_times, name, Time.now.to_i)
      @alternatives.reverse.each {|a|
        Split.redis.lpush(name, a.name)
        a.save
      }
      goals.reverse.each {|g| Split.redis.lpush(goals_key, g)} unless goals.nil?
      Split.redis.set(metric_key, metric)
      Split.redis.hset(experiment_config_key, :resettable, resettable)
      Split.redis.hset(experiment_config_key, :algorithm, algorithm.to_s)
      Split.configuration.uncache(name)
    end

    def new_record?
      !Split.configuration.experiment_for(name)
    end

    def new_version?
      config = Split.configuration.experiment_for(name)
      existing_alternatives = config[:alternatives] #load_alternatives_from_redis
      existing_goals = config[:goals] || [] #load_goals_from_redis

      !(existing_alternatives.flatten.map(&:keys).flatten == alternatives.map(&:name) && existing_goals == goals)
    end

    def ==(obj)
      # TODO: equivalency should be all properties
      self.name == obj.name
    end

    def [](name)
      alternatives.find{|a| a.name == name}
    end

    def algorithm
      @algorithm ||= Split.configuration.algorithm
    end

    def algorithm=(algorithm)
      @algorithm = algorithm.is_a?(String) ? algorithm.constantize : algorithm
    end

    def resettable=(resettable)
      @resettable = resettable.is_a?(String) ? resettable == 'true' : resettable
    end

    def alternatives=(alts)
      @alternatives = alts.map do |alternative|
        if alternative.kind_of?(Split::Alternative)
          alternative
        else
          Split::Alternative.new(alternative, @name, self)
        end
      end
    end

    def winner
      w = Split.configuration.winner(name)
      w.nil? ? nil : Split::Alternative.new(w, name, self)
    end

    def winner=(winner_name)
      Split.configuration.set_winner(name,winner_name)
      winner
    end

    def participant_count
      alternatives.inject(0){|sum,a| sum + a.participant_count}
    end

    def control
      alternatives.first
    end

    def reset_winner
      Split.configuration.reset_winner(name)
    end

    def start_time
      t = Split.redis.hget(:experiment_start_times, @name)
      if t
        # Check if stored time is an integer
        if t =~ /^[-+]?[0-9]+$/
          t = Time.at(t.to_i)
        else
          t = Time.parse(t)
        end
      end
    end

    def next_alternative
      winner || random_alternative
    end

    def random_alternative
      if alternatives.length > 1
        algorithm.choose_alternative(self)
      else
        alternatives.first
      end
    end

    def version
      @version ||= Split.configuration.experiment_versions[name.to_s].to_i
    end

    def increment_version
      @version = Split.configuration.increment_experiment_version(name.to_s)
    end

    def key
      if version.to_i > 0
        "#{name}:#{version}"
      else
        name
      end
    end

    def goals_key
      Experiment.goals_key(name)
    end
    def self.goals_key(name)
      "#{name}:goals"
    end

    def finished_key
      "#{key}:finished"
    end

    def resettable?
      resettable
    end

    def reset
      alternatives.each(&:reset)
      reset_winner
      increment_version
    end

    def delete
      reset_winner
      Split.redis.srem(:experiments, name)
      delete_alternatives
      delete_goals
      increment_version
    end

    def delete_alternatives
      load_alternatives_from_redis.each{|alt| Split.redis.del("#{@name}:#{alt.name}")}
      Split.redis.del(@name)
    end

    def delete_goals
      Split.redis.del(goals_key)
    end

    def load_from_redis
      exp_config = Split.redis.hgetall(experiment_config_key)
      self.resettable = exp_config['resettable']
      self.algorithm = exp_config['algorithm']
      self.alternatives = load_alternatives_from_redis
      self.goals = load_goals_from_redis
    end

    def self.from_redis(name)
      return nil unless Split.redis.exists(name)
      exp_config = Split.redis.hgetall(experiment_config_key(name))
      options = {}
      options[:resettable] = exp_config['resettable'] if exp_config['resettable']
      options[:algorithm] = exp_config['algorithm'] if exp_config['algorithm']
      alternatives = load_alternatives_from_redis(name)
      options[:alternatives] = alternatives if alternatives
      goals = load_goals_from_redis(name)
      options[:goals] = goals if goals
      metrics = load_metrics_from_redis(name)
      options[:metric] = metrics if metrics
      Experiment.new(name, options)
    end

    def to_hash
      alts = alternatives.map(&:to_hash)
      goals = self.goals
      options = {alternatives: alts, resettable: resettable, algorithm: algorithm}
      options[:goals] = goals if goals && goals.any?
      options[:metric] = metric if metric
      {name.to_s => options}
    end

    protected

    def self.normalize_experiment(label)
      if Hash === label
        experiment_name = label.keys.first
        goals = label.values.first
      else
        experiment_name = label
        goals = []
      end
      return experiment_name, goals
    end

    def experiment_config_key
      Experiment.experiment_config_key(name)
    end

    def self.experiment_config_key(name)
      "experiment_configurations/#{name}"
    end

    def load_goals_from_redis
      Experiment.load_goals_from_redis(name)
    end
    def self.load_goals_from_redis(name)
      Split.redis.lrange(goals_key(name), 0, -1) || []
    end

    def load_metrics_from_redis
      Experiment.load_metrics_from_redis(name)
    end
    def self.load_metrics_from_redis(name)
      #Split.redis.lrange(metrics_key(name), 0, -1) || []
      Split.redis.get(metric_key(name))
    end

    def metric_key
      Experiment.metric_key(name)
    end
    def self.metric_key(name)
      "#{name}:metrics"
    end

    def load_alternatives_from_configuration
      alts = Split.configuration.experiment_for(@name)[:alternatives]
      raise ArgumentError, "Experiment configuration is missing :alternatives array" unless alts
      if alts.is_a?(Hash)
        alts.keys
      else
        alts.flatten
      end
    end

    def load_alternatives_from_redis
      Experiment.load_alternatives_from_redis(name)
    end
    def self.load_alternatives_from_redis(name)
      alt_names = Split.redis.lrange(name, 0, -1) # lrange
      alt_names.collect {|an| Alternative.new(an, name)}
    end

  end
end

module Split
  class Alternative
    attr_accessor :name
    attr_accessor :experiment_name
    attr_accessor :weight

    def initialize(name, experiment_name, experiment = nil)
      @experiment_name = experiment_name
      if Hash === name
        if name[:name]
          @name = name[:name]
          @weight = name[:percent]
        else
          @name = name.keys.first
          @weight = name.values.first
        end
      else
        @name = name
        @weight = (weight_from_redis || 1).to_f
      end
      @_experiment = experiment
    end

    def to_s
      name
    end

    def to_hash
      {name: name, percent: weight}
    end

    def goals
      self.experiment.goals
    end

    def participant_count
      Split.redis.hget(key, 'participant_count').to_i
    end

    def participant_count=(count)
      Split.redis.hset(key, 'participant_count', count.to_i)
    end

    def completed_count(goal = nil)
      field = set_field(goal)
      Split.redis.hget(key, field).to_i
    end

    def all_completed_count
      if goals.empty?
        completed_count
      else
        goals.inject(completed_count) do |sum, g|
          sum + completed_count(g)
        end
      end
    end

    def unfinished_count
      participant_count - all_completed_count
    end

    def set_field(goal)
      field = "completed_count"
      field += ":" + goal unless goal.nil?
      return field
    end

    def set_completed_count (count, goal = nil)
      field = set_field(goal)
      Split.redis.hset(key, field, count.to_i)
    end

    def increment_participation
      Split.redis.hincrby key, 'participant_count', 1
    end

    def increment_completion(goal = nil)
      field = set_field(goal)
      Split.redis.hincrby(key, field, 1)
    end

    def control?
      experiment.control.name == self.name
    end

    def conversion_rate(goal = nil)
      return 0 if participant_count.zero?
      (completed_count(goal).to_f)/participant_count.to_f
    end

    def experiment
      @_experiment ||= Split::Experiment.find(experiment_name)
    end

    def z_score(goal = nil)
      # CTR_E = the CTR within the experiment split
      # CTR_C = the CTR within the control split
      # E = the number of impressions within the experiment split
      # C = the number of impressions within the control split

      control = experiment.control

      alternative = self

      return 'N/A' if control.name == alternative.name

      ctr_e = alternative.conversion_rate(goal)
      ctr_c = control.conversion_rate(goal)


      e = alternative.participant_count
      c = control.participant_count

      return 0 if ctr_c.zero?

      standard_deviation = ((ctr_e / ctr_c**3) * ((e*ctr_e)+(c*ctr_c)-(ctr_c*ctr_e)*(c+e))/(c*e)) ** 0.5

      z_score = ((ctr_e / ctr_c) - 1) / standard_deviation
    end

    def save
      Split.redis.hsetnx key, 'weight', (weight)
      Split.redis.hsetnx key, 'participant_count', 0
      Split.redis.hsetnx key, 'completed_count', 0
    end

    def validate!
      unless String === @name || hash_with_correct_values?(@name)
        raise ArgumentError, 'Alternative must be a string'
      end
    end

    def reset
      Split.redis.hmset key, 'participant_count', 0, 'completed_count', 0
      unless goals.empty?
        goals.each do |g|
          field = "completed_count:#{g}"
          Split.redis.hset key, field, 0
        end
      end
    end

    def delete
      Split.redis.del(key)
    end

    private

    def weight_from_redis
      Split.redis.hget key, 'weight' if Split.configuration.enabled
    end

    def hash_with_correct_values?(name)
      Hash === name && String === name.keys.first && Float(name.values.first) rescue false
    end

    def key
      "#{experiment_name}:#{name}"
    end
  end
end

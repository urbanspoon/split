module Split
  module Helper

    def ab_test(metric_descriptor, control=nil, *alternatives)
      update_split_configuration
      if RUBY_VERSION.match(/1\.8/) && alternatives.length.zero? && ! control.nil?
        puts 'WARNING: You should always pass the control alternative through as the second argument with any other alternatives as the third because the order of the hash is not preserved in ruby 1.8'
      end

      # Check if array is passed to ab_test: ab_test('name', ['Alt 1', 'Alt 2', 'Alt 3'])
      if control.is_a? Array and alternatives.length.zero?
        control, alternatives = control.first, control[1..-1]
      end

      begin
      experiment_name_with_version, goals = normalize_experiment(metric_descriptor)
      experiment_name = experiment_name_with_version.to_s.split(':')[0]
      experiment = Split::Experiment.new(experiment_name, :alternatives => [control].compact + alternatives, :goals => goals)
      control ||= experiment.control && experiment.control.name

        ret = if Split.configuration.enabled
          experiment.save # *allrediscommands?*
          start_trial( Trial.new(:experiment => experiment) )
            #hget 'split:experiment_winner' '[name]'
        else
          control_variable(control)
        end

      rescue => e
        raise(e) unless Split.configuration.db_failover
        Split.configuration.db_failover_on_db_error.call(e)

        if Split.configuration.db_failover_allow_parameter_override && override_present?(experiment_name)
          ret = override_alternative(experiment_name)
        end
      ensure
        unless ret
          ret = control_variable(control)
        end
      end

      if block_given?
        if defined?(capture) # a block in a rails view
          block = Proc.new { yield(ret) }
          concat(capture(ret, &block))
          false
        else
          yield(ret)
        end
      else
        ret
      end
    end

    def reset!(experiment)
      ab_user.delete(experiment.key)
    end

    def finish_experiment(experiment, options = {:reset => true})
      return true unless experiment.winner.nil?
      should_reset = experiment.resettable? && options[:reset]
      if ab_user[experiment.finished_key] && !should_reset
        return true
      else
        alternative_name = ab_user[experiment.key]
        trial = Trial.new(:experiment => experiment, :alternative => alternative_name, :goals => options[:goals])
        trial.complete!
        call_trial_complete_hook(trial)

        if should_reset
          reset!(experiment)
        else
          ab_user[experiment.finished_key] = true
        end
      end
    end


    def finished(metric_descriptor, options = {:reset => true})
      return if exclude_visitor? || Split.configuration.disabled?
      metric_descriptor, goals = normalize_experiment(metric_descriptor)
      experiments = Metric.possible_experiments(metric_descriptor)

      if experiments.any?
        experiments.each do |experiment|
          finish_experiment(experiment, options.merge(:goals => goals))
        end
      end
    rescue => e
      raise unless Split.configuration.db_failover
      Split.configuration.db_failover_on_db_error.call(e)
    end

    def override_present?(experiment_name)
      defined?(params) && params[experiment_name]
    end

    def override_alternative(experiment_name)
      params[experiment_name] if override_present?(experiment_name)
    end

    def begin_experiment(experiment, alternative_name = nil)
      alternative_name ||= experiment.control.name
      ab_user[experiment.key] = alternative_name
      alternative_name
    end

    def ab_user
      @ab_user ||= Split::Persistence.adapter.new(self)
    end

    def exclude_visitor?
      instance_eval(&Split.configuration.ignore_filter)
    end

    def clean_old_experiments
      participating_experiments = ab_user.keys.collect{|k| k.split(':')}

      config_experiments = Split.configuration.normalized_experiments.keys
      config_experiments = config_experiments.collect{|k| [k, Split.configuration.experiment_versions[k]].compact}

      potential_unknowns = participating_experiments - config_experiments

      if potential_unknowns.length > 0
        datastore_experiments = Split::Experiment.names
        datastore_experiments = datastore_experiments.collect{|k| [k, Split.configuration.experiment_versions[k]].compact}

        unrecognized_experiments = potential_unknowns - datastore_experiments
        unrecognized_experiments.each do |old_experiment|
          ab_user.keys.select{|k| k.match /^#{old_experiment[0]}(:\d+)?$/}.each do |key|
            ab_user.delete key
          end
        end
      end
    end

    def not_allowed_to_test?(experiment_key)
      !Split.configuration.allow_multiple_experiments && doing_other_tests?(experiment_key)
    end

    def doing_other_tests?(experiment_key)
      keys_without_experiment(ab_user.keys, experiment_key).length > 0
    end

    def clean_old_versions(experiment)
      old_versions(experiment).each do |old_key|
        ab_user.delete old_key
      end
    end

    def old_versions(experiment)
      if experiment.version > 0 #get 'split:[name]:version'
        keys = ab_user.keys.select { |k| k.match(Regexp.new(experiment.name)) }
        keys_without_experiment(keys, experiment.key)
      else
        []
      end
    end

    def is_robot?
      defined?(request) && request.user_agent =~ Split.configuration.robot_regex
    end

    def is_ignored_ip_address?
      return false if Split.configuration.ignore_ip_addresses.empty?

      Split.configuration.ignore_ip_addresses.each do |ip|
        return true if defined?(request) && (request.ip == ip || (ip.class == Regexp && request.ip =~ ip))
      end
      false
    end

    protected

    def update_split_configuration
      unless @_split_config_updated
        Split.configuration.update
        @_split_config_updated = true
      end
    end

    def normalize_experiment(metric_descriptor)
      if Hash === metric_descriptor
        experiment_name = metric_descriptor.keys.first.to_s
        goals = Array(metric_descriptor.values.first)
      else
        experiment_name = metric_descriptor.to_s
        goals = []
      end
      return experiment_name, goals
    end

    def control_variable(control)
      Hash === control ? control.keys.first : control
    end

    def start_trial(trial)
      experiment = trial.experiment
      if override_present?(experiment.name)
        ret = override_alternative(experiment.name)
        store_override(experiment.key, ret)
      elsif ! experiment.winner.nil? #hget 'split:experiment_winner' '[name]'
        # TODO: what should happen if the 'winner' is cleared? go back to persisted choice, or reselect?
        # TODO: previous participation in experiment with 'winner' makes you ineligible for another experiment despite clean_old_experiments()
        ret = experiment.winner.name
      else
        clean_old_experiments
        if exclude_visitor? || not_allowed_to_test?(experiment.key)
          ret = experiment.control.name
        else
          if ab_user[experiment.key]
            ret = ab_user[experiment.key]
          else
            trial.choose!
            call_trial_choose_hook(trial)
            ret = begin_experiment(experiment, trial.alternative.name)
          end
        end
      end

      ret
    end

    def store_override(key, value)
      if Split.configuration.store_override
        ab_user.keys.each {|k| ab_user.delete(k)}
        ab_user[key] = value
      end
    end

    def call_trial_choose_hook(trial)
      send(Split.configuration.on_trial_choose, trial) if Split.configuration.on_trial_choose
    end

    def call_trial_complete_hook(trial)
      send(Split.configuration.on_trial_complete, trial) if Split.configuration.on_trial_complete
    end

    def keys_without_experiment(keys, experiment_key)
      keys.reject { |k| k.match(Regexp.new("^#{experiment_key}(:finished)?$")) }
    end
  end
end

Rails.application.config.after_initialize do
  if ActiveRecord::Base.connected?
    ActiveRecord::Base.connection_pool.disconnect!
  end

  ActiveSupport.on_load(:active_record) do
    # In Rails 7, configurations is an ActiveRecord::DatabaseConfigurations object
    db_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).first
    if db_config
      config = db_config.configuration_hash.to_h.dup
      config['pool'] = ENV['RAILS_MAX_THREADS'] || 5
      ActiveRecord::Base.establish_connection(config)
    end
  end
end

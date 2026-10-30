# frozen_string_literal: true

module ActionCable
  module SubscriptionAdapter
    class Cloud
      class Railtie < Rails::Railtie
        # Always installed: the middleware only acts once cable.yml selects the
        # cloud adapter, which isn't known until Action Cable loads.
        initializer "laravel_cloud.action_cable" do |app|
          app.middleware.use(Middleware)
        end
      end
    end
  end
end

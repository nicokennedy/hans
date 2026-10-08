Rails.application.routes.draw do
  devise_for :users

  mount ActionCable.server => "/cable"

  root "pages#home"

  resource :dashboard, only: [:show]

  resource :cart, only: [:show] do
    post :add
    patch :update_item
    delete :remove_item
    delete :clear
  end

  resources :orders, only: [:new, :create, :show, :index] do
    post :repeat, on: :member
  end

  get "/production/:id/print", to: "admin/production#public_print", as: :public_production_print

  namespace :admin do
    get 'production/index'
    root "dashboard#show"
    resources :orders, only: [:index, :show, :new, :create, :edit, :update] do
      resources :payments, only: [:create, :destroy]
      get :export, on: :collection
      get :receipts, on: :collection
    end
    resources :production, only: [:index, :show] do
      get :print, on: :member
    end
    resources :products do
      member do
        get "inline/:field", action: :edit_inline, as: :edit_inline
        patch "inline/:field", action: :update_inline, as: :update_inline
      end
      collection do
        get :import
        post :preview_import
        post :confirm_import
      end
      resources :stock_sources, only: [:create, :destroy], controller: "product_stock_sources"
      resource :product_recipe, only: [:new, :create, :edit, :update] do
        post :activate
        post :deactivate
        resources :recipe_components, only: [:create, :update, :destroy], controller: "product_recipe_components"
      end
    end
    resources :customers, only: [:index, :show, :new, :create, :edit, :update] do
      patch :toggle_active, on: :member
      # Cuenta corriente: estado de cuenta, pagos globales repartidos entre pedidos y
      # saldo a favor (ver CustomerAccounts::*).
      resource :account, only: [:show], controller: "customer_accounts"
      resources :customer_payments, only: [:new, :create] do
        post :void, on: :member
      end
      resources :credit_applications, only: [:new, :create] do
        post :revert, on: :member
      end
    end
    resources :categories
    resources :raw_materials, only: [:index, :new, :create, :edit, :update]
    resources :preparations, only: [:index, :new, :create, :edit, :update] do
      resources :recipe_components, only: [:create, :update, :destroy]
    end
    # Vista administrativa sobre Product + ProductRecipe existentes — no es
    # un modelo/concepto nuevo, solo un índice más visible que "adentro de
    # cada Producto" (ver Admin::RecipesController).
    resources :recipes, only: [:index]

    # Pantalla de administración de DeliverySetting — por ahora solo expone
    # las fechas excepcionales de entrega (ver Admin::DeliverySettingsController
    # y Admin::ExceptionalDeliveryDatesController). No hay :id porque
    # DeliverySetting.current es un singleton.
    resource :delivery_settings, only: [:show]
    resources :exceptional_delivery_dates, only: [:create, :destroy]

    # Módulo Stock/Producción. StockItem no tiene rutas nested bajo
    # products/preparations a propósito: el form de alta/edición (embebido
    # en la pantalla del Product/Preparation) manda stockable_type/id como
    # campos ocultos — mismo criterio "un solo controller, tipo resuelto
    # desde el propio payload" que ya usa RecipeComponent (ver
    # RecipeComponent.resolve_component). show es el panel diario; las
    # acciones de producción/conteo son las únicas que puede usar el perfil
    # production (ver Admin::StockController/Admin::StockItemsController).
    resource :stock, only: [:show], controller: "stock"
    resources :stock_items, only: [:show, :create, :update] do
      member do
        post :register_production
        post :register_count
        get :edit_config
        patch :update_config
      end
    end

    resource :push_settings, only: [:show]
    resources :push_subscriptions, only: [:create, :destroy] do
      post :test, on: :member
    end
  end
end

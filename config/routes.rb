Rails.application.routes.draw do
  devise_for :users

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
    end
    resources :customers, only: [:index, :show, :new, :create, :edit, :update] do
      patch :toggle_active, on: :member
    end
    resources :categories
  end
end

# frozen_string_literal: true

module V1
  # INHERITS THE ENGINE'S BASE, WHICH IS THE OPPOSITE OF WHAT THE MAKER APP DOES -- and the
  # difference is the whole point of both decisions.
  #
  # In chaim354/tinkerex the host had to stop inheriting `Sync::V1::BaseController`, because share
  # and s3 deployments do not load the engine at all and a superclass is resolved when the class
  # body loads. Here the engine is not optional: it IS the application. There is no configuration of
  # this host in which `Sync::V1::BaseController` is absent, so inheriting it is free and gives
  # device-token auth and the five rescue arms without a second copy.
  class BaseController < Sync::V1::BaseController
  end
end

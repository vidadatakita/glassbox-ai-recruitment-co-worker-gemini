class ApplicationController < ActionController::Base
  include Authentication

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # NOTE: the generator's `allow_browser versions: :modern` is NOT here on purpose. It answers
  # 406 to older browsers, and candidates apply from whatever phone they have (R8). It applies
  # to staff screens only (Staff::BaseController, SessionsController).
end

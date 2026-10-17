# The AI interview retries a busy AI after a short pause; tests do not wait.
class ActiveSupport::TestCase
  setup { Interviews::Next.pauses = [0, 0] }
end

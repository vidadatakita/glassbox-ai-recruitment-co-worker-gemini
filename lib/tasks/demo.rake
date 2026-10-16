namespace :glassbox do
  namespace :demo do
    desc "DEMO_MODE=1 only: drop the schema, reload db/structure.sql and reseed the demo workspace (what the nightly job does)"
    task reset: :environment do
      result = Demo::Reset.call
      abort "demo:reset refused: #{result.error}" unless result.success?
      puts "demo:reset done in #{result.payload[:duration_ms]} ms: users #{result.payload[:users]}, jobs #{result.payload[:jobs]}, applications #{result.payload[:applications]}"
    end
  end
end

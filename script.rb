# frozen_string_literal: true
require "net/http"
require "uri"
require "json"
require "csv"
require "dotenv/load" # loads .env file if present

API_BASE = "https://fr24api.flightradar24.com"
API_TOKEN = ENV.fetch("FR24_API_TOKEN") # set your token in env
HEADERS = {
  "Accept" => "application/json",
  "Accept-Version" => "v1",
  "Authorization" => "Bearer #{API_TOKEN}"
}

REGISTRATION = "D-AIEP"
DAY_FROM = "2025-08-22T00:00:00Z"
DAY_TO   = "2025-08-23T00:00:00Z"

# Heuristic to keep only in-flight points (exclude taxi/ground).
# Tune as needed. If you prefer only "airborne", increase ALT_FT_MIN or SPD_KT_MIN.
ALT_FT_MIN   = 32 # feet
SPD_KT_MIN   = 10 # knots

def http_get(path, params = {})
  puts "Calling GET #{path} with #{params.inspect}"
  uri = URI.join(API_BASE, path)
  uri.query = URI.encode_www_form(params) if params && !params.empty?
  req = Net::HTTP::Get.new(uri, HEADERS)

  result =
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      res = http.request(req)
      raise "#{res.code} #{res.message}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
      JSON.parse(res.body)
    end

  puts "  => got #{result.class}: #{result}"

  result
end

puts "1) Find all flight legs (fr24_id) for D-AIEP on the day"
summary = http_get("/api/flight-summary/light", {
  "registrations" => REGISTRATION,
  "flight_datetime_from" => DAY_FROM,
  "flight_datetime_to"   => DAY_TO
})
flight_ids = summary.fetch("data", []).map { |f| f["fr24_id"] }.compact.uniq

puts ">>> flight_ids: #{flight_ids.inspect}"

puts "2) For each leg, fetch tracks and collect filtered points"
all_points = []
flight_ids.each do |fid|
  tracks = http_get("/api/flight-tracks", { "flight_id" => fid }).first # returns { fr24_id, tracks: [...] }

  (tracks["tracks"] || []).each do |pt|
    alt   = pt["alt"]
    gspd  = pt["gspeed"]
    next if alt.nil? || gspd.nil?
    next if alt < ALT_FT_MIN || gspd < SPD_KT_MIN

    all_points << {
      "latitude"  => pt["lat"],
      "longitude" => pt["lon"],
      "timestamp" => pt["timestamp"],  # already UTC ISO8601 per spec
      "altitude"  => alt,              # feet AMSL
      "speed"     => gspd,             # knots
      "direction" => pt["track"]       # degrees (0-360)
    }
  end
end

puts "3) Sort by timestamp and write to CSV file"
all_points.sort_by! { |p| p["timestamp"] }

# Generate filename with timestamp
timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
filename = "result_#{timestamp}.csv"

# Write to CSV file
CSV.open(filename, "w") do |csv|
  # Add header row
  csv << ["latitude", "longitude", "timestamp", "altitude", "speed", "direction"]

  # Add data rows
  all_points.each do |point|
    csv << [
      point["latitude"],
      point["longitude"],
      point["timestamp"],
      point["altitude"],
      point["speed"],
      point["direction"]
    ]
  end
end

puts "CSV data written to: #{filename}"

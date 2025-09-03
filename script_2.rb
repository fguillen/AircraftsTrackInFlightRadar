# frozen_string_literal: true
require "net/http"
require "uri"
require "json"
require "csv"
require "dotenv/load"
API_BASE = "https://fr24api.flightradar24.com"
API_TOKEN = ENV.fetch("FR24_API_TOKEN")
HEADERS = {
  "Accept" => "application/json",
  "Accept-Version" => "v1",
  "Authorization" => "Bearer #{API_TOKEN}"
}
AIRCRAFTS = %w[
  d-aiep d-aijf d-aine d-aign d-aira d-aimh d-aieb d-aizz d-aine d-aiph
  d-aimk d-ainq d-airb d-aipx d-aibf d-aiph d-aimj d-ainl d-aieq d-aipy
]
DAY_FROM = "2025-08-25T00:00:00Z"
DAY_TO   = "2025-08-31T23:59:59Z"
ALT_FT_MIN = 32
SPD_KT_MIN = 10
def http_get(path, params = {})
  uri = URI.join(API_BASE, path)
  uri.query = URI.encode_www_form(params) if params && !params.empty?
  req = Net::HTTP::Get.new(uri, HEADERS)
  result =
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      res = http.request(req)
      raise "#{res.code} #{res.message}: #{res.body}" unless res.is_a?(Net::HTTPSuccess)
      JSON.parse(res.body)
    end
  result
rescue => e
  if e.to_s.include?("429") || e.to_s.include?("too many requests")
    puts "Rate limited, sleeping 20 seconds and retrying..."
    sleep 20
    retry
  else
    raise
  end
end
# Gemeinsame CSV-Datei (alle Flugzeuge + Zeitraum)
timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
filepath = "results/result_#{timestamp}_all_aircrafts_#{DAY_FROM}_#{DAY_TO}.csv"
CSV.open(filepath, "w") do |csv|
  csv << ["aircraft", "latitude", "longitude", "timestamp", "altitude", "speed", "direction"]
  AIRCRAFTS.each do |aircraft|
    puts "=== Processing aircraft #{aircraft} ==="
    summary =
      http_get("/api/flight-summary/light", {
        "registrations" => aircraft,
        "flight_datetime_from" => DAY_FROM,
        "flight_datetime_to"   => DAY_TO
      })
    flight_ids = summary.fetch("data", []).map { |f| f["fr24_id"] }.compact.uniq
    puts ">>> flight_ids for #{aircraft} (#{flight_ids.count})"
    flight_ids.each_with_index do |fid, index|
      puts ">>> Getting positions for #{aircraft}, flight_id #{fid} [#{index + 1}/#{flight_ids.size}]"
      tracks = http_get("/api/flight-tracks", { "flight_id" => fid }).first
      (tracks["tracks"] || []).each do |pt|
        alt   = pt["alt"]
        gspd  = pt["gspeed"]
        next if alt.nil? || gspd.nil?
        next if alt < ALT_FT_MIN || gspd < SPD_KT_MIN
        csv << [
          aircraft,
          pt["lat"],
          pt["lon"],
          pt["timestamp"],
          alt,
          gspd,
          pt["track"]
        ]
      end
      sleep 10 if flight_ids.size > 1
    end
  end
end

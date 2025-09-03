# frozen_string_literal: true
require "net/http"
require "uri"
require "json"
require "csv"
require "yaml"
require "dotenv/load" # loads .env file if present
# require "byebug"

API_BASE = "https://fr24api.flightradar24.com"


# Heuristic to keep only in-flight points (exclude taxi/ground).
# Tune as needed. If you prefer only "airborne", increase ALT_FT_MIN or SPD_KT_MIN.
ALT_FT_MIN   = 32 # feet
SPD_KT_MIN   = 10 # knots

class AircraftPositionsScrapper
  def initialize(aircrafts, day_from, day_to, real_api_calls = false)
    puts "Initializing AircraftPositionsScrapper"
    puts "Aircrafts: #{aircrafts.join(", ")}"
    puts "Date Range: #{day_from} to #{day_to}"
    puts "Real API Calls: #{real_api_calls}"

    @aircrafts = aircrafts
    @day_from = day_from
    @day_to = day_to
    @api_token =
      if real_api_calls
        ENV.fetch("FR24_API_TOKEN_PRODUCTION")
      else
        ENV.fetch("FR24_API_TOKEN_TEST")
      end
  end

  def run
    @aircrafts.each_with_index do |aircraft, index|
      puts "Processing aircraft #{index + 1}/#{@aircrafts.size}: #{aircraft}"
      AircraftPositionsScrapper.scrap_aircraft(aircraft, @day_from, @day_to, @api_token)
    end
  end

  private

  def self.scrap_aircraft(aircraft, day_from, day_to, api_token)
    puts "1) Find all flight legs (fr24_id) for #{aircraft} on dates #{day_from} to #{day_to}"
    fr24_flight_ids = get_flight_ids(aircraft, day_from, day_to, api_token)

    puts ">>> flight_ids (#{fr24_flight_ids.count})"

    puts "2) For each leg, fetch tracks and collect filtered points"
    all_points = get_flights_location_points(fr24_flight_ids, api_token)

    # Generate filename with timestamp
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    filepath = "results/result_#{timestamp}_#{aircraft}_#{day_from}_#{day_to}.csv"
    puts "3) Write to CSV file: #{filepath}"
    write_to_csv(filepath, all_points)
  end

  def self.write_to_csv(filepath, points)
    CSV.open(filepath, "w") do |csv|
      # Add header row
      csv << ["latitude", "longitude", "timestamp", "altitude", "speed", "direction"]

      # Add data rows
      points.each do |point|
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

    puts "CSV data written to: #{filepath}"
  end

  def self.get_flights_location_points(fr24_flight_ids, api_token)
    all_points = []

    fr24_flight_ids.each_with_index do |fid, index|
      puts ">>> Getting positions for flight_id #{fid} [#{index + 1}/#{fr24_flight_ids.size}]"

      response_body = http_get("/api/flight-tracks", { "flight_id" => fid }, api_token).first # returns { fr24_id, tracks: [...] }

      (response_body["tracks"] || []).each do |pt|
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

      # sleep 10 if fr24_flight_ids.size > 1 # be nice to the API if multiple calls
    end

    all_points.sort_by! { |p| p["timestamp"] }
    all_points
  end

  def self.get_flight_ids(aircraft, day_from, day_to, api_token)
    day_from_time_stamp = Time.parse(day_from).utc.iso8601
    day_to_time_stamp = Time.parse("#{day_to} 23:59:59 UTC").utc.iso8601

    summary =
      http_get(
        "/api/flight-summary/light",
        {
          "registrations" => aircraft,
          "flight_datetime_from" => day_from_time_stamp,
          "flight_datetime_to"   => day_to_time_stamp
        },
        api_token
      )

    summary.fetch("data", []).map { |f| f["fr24_id"] }.compact.uniq
  end

  def self.http_get(path, params = {}, api_token)
    puts ">>> Calling GET #{path} with #{params.inspect}"

    headers = {
      "Accept" => "application/json",
      "Accept-Version" => "v1",
      "Authorization" => "Bearer #{api_token}"
    }

    uri = URI.join(API_BASE, path)
    uri.query = URI.encode_www_form(params) if params && !params.empty?
    req = Net::HTTP::Get.new(uri, headers)

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
end


def load_configuration(config_path = "#{File.dirname(__FILE__)}/config.yml")
  config = YAML.safe_load(File.read(config_path))
  {
    aircrafts: config["aircrafts"],
    day_from: config["day_from"],
    day_to: config["day_to"],
    real_api_calls: config["real_api_calls"]
  }
end

configuration = load_configuration
AircraftPositionsScrapper.new(
  configuration[:aircrafts],
  configuration[:day_from],
  configuration[:day_to],
  configuration[:real_api_calls]
).run

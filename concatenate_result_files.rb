require "csv"

results_dir = File.join(__dir__, "results")
output_file = File.join(__dir__, "results", "concatenated_results.csv")

csv_files = Dir.glob(File.join(results_dir, "*.csv")).reject { |f| File.basename(f) == "concatenated_results.csv" }

CSV.open(output_file, "w") do |out_csv|
  csv_files.each_with_index do |file, idx|
    CSV.foreach(file) do |row|
      if idx == 0 || $. > 1
        out_csv << row
      end
    end
  end
end

puts "Concatenated #{csv_files.size} files into #{output_file}"

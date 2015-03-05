module Embulk
  module Guess
    require_relative 'schema_guess'

    class CsvGuessPlugin < LineGuessPlugin
      Plugin.register_guess('csv', self)

      DELIMITER_CANDIDATES = [
        ",", "\t", "|"
      ]

      QUOTE_CANDIDATES = [
        "\"", "'"
      ]

      ESCAPE_CANDIDATES = [
        "\\"
      ]

      NULL_STRING_CANDIDATES = [
        "null",
        "NULL",
        "#N/A",
        "\\N",  # MySQL LOAD, Hive STORED AS TEXTFILE
      ]

      def guess_lines(config, sample_lines)
        delim = guess_delimiter(sample_lines)
        unless delim
          # not CSV file
          return {}
        end

        parser_config = config["parser"] || {}
        parser_guessed = {"type" => "csv", "delimiter" => delim}

        quote = guess_quote(sample_lines, delim)
        parser_guessed["quote"] = quote ? quote : ''

        escape = guess_escape(sample_lines, delim, quote)
        parser_guessed["escape"] = escape ? escape : ''

        null_string = guess_null_string(sample_lines, delim)
        parser_guessed["null_string"] = null_string if null_string
        # don't even set null_string to avoid confusion of null and 'null' in YAML format

        sample_records = sample_lines.map {|line| line.split(delim) }  # TODO use CsvTokenizer
        first_types = SchemaGuess.types_from_array_records(sample_records[0, 1])
        other_types = SchemaGuess.types_from_array_records(sample_records[1..-1])

        if first_types.size <= 1 || other_types.size <= 1
          # guess failed
          return {}
        end

        unless parser_config.has_key?("header_line")
          parser_guessed["header_line"] = (first_types != other_types && !first_types.any? {|t| t != "string" })
        end

        unless parser_config.has_key?("columns")
          if parser_guessed["header_line"] || parser_config["header_line"]
            column_names = sample_records.first
          else
            column_names = (0..other_types.size).to_a.map {|i| "c#{i}" }
          end
          schema = []
          column_names.zip(other_types).each do |name,type|
            if name && type
              if type.is_a?(SchemaGuess::TimestampTypeMatch)
                schema << {"name" => name, "type" => type, "format" => type.format}
              else
                schema << {"name" => name, "type" => type}
              end
            end
          end
          parser_guessed["columns"] = schema
        end

        return {"parser" => parser_guessed}
      end

      private

      def guess_delimiter(sample_lines)
        delim_weights = DELIMITER_CANDIDATES.map do |d|
          counts = sample_lines.map {|line| line.count(d) }
          total = array_sum(counts)
          if total > 0
            stddev = array_standard_deviation(counts)
            stddev = 0.000000001 if stddev == 0.0
            weight = total / stddev
            [d, weight]
          else
            [nil, 0]
          end
        end

        delim, weight = *delim_weights.sort_by {|d,weight| weight }.last
        if delim != nil && weight > 1
          return delim
        else
          return nil
        end
      end

      def guess_quote(sample_lines, delim)
        delim_regexp = Regexp.escape(delim)
        quote_weights = QUOTE_CANDIDATES.map do |q|
          weights = sample_lines.map do |line|
            q_regexp = Regexp.escape(q)
            count = line.count(q)
            if count > 0
              weight = count
              weight += line.scan(/(?:\A|#{delim_regexp})\s*#{q_regexp}(?:(?!#{q_regexp}).)*\s*#{q_regexp}(?:$|#{delim_regexp})/).size * 20
              weight += line.scan(/(?:\A|#{delim_regexp})\s*#{q_regexp}(?:(?!#{delim_regexp}).)*\s*#{q_regexp}(?:$|#{delim_regexp})/).size * 40
              weight
            else
              nil
            end
          end.compact
          weights.empty? ? 0 : array_avg(weights)
        end
        quote, weight = QUOTE_CANDIDATES.zip(quote_weights).sort_by {|q,w| w }.last
        if weight >= 10.0
          return quote
        else
          return nil
        end
      end

      def guess_escape(sample_lines, delim, optional_quote)
        guessed = ESCAPE_CANDIDATES.map do |str|
          if optional_quote
            regexp = /#{Regexp.quote(str)}(?:#{Regexp.quote(delim)}|#{Regexp.quote(optional_quote)})/
          else
            regexp = /#{Regexp.quote(str)}#{Regexp.quote(delim)}/
          end
          counts = sample_lines.map {|line| line.scan(regexp).count }
          count = counts.inject(0) {|r,c| r + c }
          [str, count]
        end.select {|str,count| count > 0 }.sort_by {|str,count| -count }
        found = guessed.first
        return found ? found[0] : nil
      end

      def guess_null_string(sample_lines, delim)
        guessed = NULL_STRING_CANDIDATES.map do |str|
          regexp = /(?:^|#{Regexp.quote(delim)})#{Regexp.quote(str)}(?:$|#{Regexp.quote(delim)})/
          counts = sample_lines.map {|line| line.scan(regexp).count }
          count = counts.inject(0) {|r,c| r + c }
          [str, count]
        end.select {|str,count| count > 0 }.sort_by {|str,count| -count }
        found = guessed.first
        return found ? found[0] : nil
      end

      def array_sum(array)
        array.inject(0) {|r,i| r += i }
      end

      def array_avg(array)
        array.inject(0.0) {|r,i| r += i } / array.size
      end

      def array_variance(array)
        avg = array_avg(array)
        array.inject(0.0) {|r,i| r += (i - avg) ** 2 } / array.size
      end

      def array_standard_deviation(array)
        Math.sqrt(array_variance(array))
      end
    end

  end
end
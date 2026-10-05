module Muxr
  class PaneFilter
    FIELDS = {
      "cmd" => :command, "c" => :command,
      "session" => :session, "s" => :session,
      "name" => :name, "n" => :name,
      "title" => :title, "t" => :title,
      "cwd" => :cwd, "dir" => :cwd,
      "id" => :pane_id
    }.freeze

    TEXT_FIELDS = %i[session pane_id name command title cwd notice].freeze

    STATES = %w[busy error active idle].freeze

    def initialize(query)
      @terms = query.to_s.downcase.split
    end

    def match?(entry)
      @terms.all? { |term| term_matches?(entry, term) }
    end

    private

    def term_matches?(entry, term)
      if term.length > 1 && term.start_with?("-")
        !positive_match?(entry, term[1..])
      else
        positive_match?(entry, term)
      end
    end

    def positive_match?(entry, term)
      key, sep, value = term.partition(":")
      return text_match?(entry, TEXT_FIELDS, term) if sep.empty? || value.empty?
      return flag_match?(entry, value) if key == "is"
      field = FIELDS[key]
      return text_match?(entry, TEXT_FIELDS, term) unless field
      text_match?(entry, [field], value)
    end

    def text_match?(entry, fields, needle)
      fields.any? { |field| entry.public_send(field).to_s.downcase.include?(needle) }
    end

    def flag_match?(entry, flag)
      return entry.state == flag if STATES.include?(flag)
      case flag
      when "bell"      then !!entry.bell
      when "activity"  then !!entry.activity
      when "silent"    then !!entry.silent
      when "attention" then entry.attention?
      when "here"      then !!entry.here
      when "private"   then !!entry.private
      when "focused"   then !!entry.focused
      else false
      end
    end
  end
end

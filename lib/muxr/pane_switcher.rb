require "muxr/pane_filter"

module Muxr
  class PaneSwitcher
    attr_reader :query, :rows, :index, :entries

    def initialize(entries, query: "")
      @entries = entries
      @query = +query.to_s
      @index = 0
      apply_filter
    end

    def empty?
      @rows.empty?
    end

    def selected
      @rows[@index]
    end

    def move(delta)
      return if empty?
      @index = (@index + delta) % @rows.length
    end

    def type(text)
      @query << text
      refilter
    end

    def backspace
      return if @query.empty?
      @query.chop!
      refilter
    end

    def clear_query
      @query.clear
      refilter
    end

    def replace_entries(entries)
      keep = selected&.label
      @entries = entries
      apply_filter
      found = keep && @rows.index { |entry| entry.label == keep }
      @index = found || @index.clamp(0, [@rows.length - 1, 0].max)
    end

    private

    def refilter
      @index = 0
      apply_filter
    end

    def apply_filter
      filter = PaneFilter.new(@query)
      @rows = @entries.select { |entry| filter.match?(entry) }
    end
  end
end

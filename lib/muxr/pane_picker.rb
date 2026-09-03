module Muxr
  # Selection state for the attach overlay: a flat, navigable list of every
  # pane offered by the other muxr servers on this machine, with session
  # headings interleaved so the list reads as a grouped tree while the cursor
  # only ever lands on something selectable.
  class PanePicker
    Row = Struct.new(:kind, :session, :entry) do
      def selectable?
        kind == :pane
      end
    end

    attr_reader :rows, :index

    def initialize(entries)
      @rows = build_rows(entries)
      @index = @rows.index(&:selectable?) || 0
    end

    def empty?
      @rows.none?(&:selectable?)
    end

    def selected
      row = @rows[@index]
      row&.selectable? ? row.entry : nil
    end

    def move(delta)
      return if empty?
      i = @index
      @rows.length.times do
        i = (i + delta) % @rows.length
        next unless @rows[i].selectable?
        @index = i
        return
      end
    end

    private

    def build_rows(entries)
      entries.group_by(&:session).flat_map do |session, panes|
        [Row.new(:session, session, nil)] +
          panes.map { |entry| Row.new(:pane, session, entry) }
      end
    end
  end
end

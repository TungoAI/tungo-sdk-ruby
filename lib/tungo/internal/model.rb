# frozen_string_literal: true

module Tungo
  module Internal
    # Converts JSON values into typed values and back. A type is described by a spec:
    # +:string+, +:integer+, +:number+, +:boolean+, +:any+, the name of a constant in
    # {Tungo::Models} (+:Company+), +[:array, spec]+ or +[:map, spec]+.
    #
    # Converting never raises: a value of an unexpected shape is kept as it is, so that no data
    # is lost. What the API sent is checked separately and lightly by {mismatch}: only the
    # properties of the top-level object, only their JSON kind; +null+, unknown properties,
    # unknown enumeration values and missing properties are always accepted, so a newer API
    # does not break an older SDK.
    module Type
      PRIMITIVES = %i[string integer number boolean any].freeze

      module_function

      # @return [Object] the typed, deeply frozen value
      def coerce(spec, value)
        return nil if value.nil?

        case spec
        when Symbol
          PRIMITIVES.include?(spec) ? plain(value) : Tungo::Models.const_get(spec).coerce(value)
        when Array
          coerce_collection(spec, value)
        else
          plain(value)
        end
      end

      def coerce_collection(spec, value)
        kind, element = spec
        if kind == :array && value.is_a?(Array)
          value.map { |item| coerce(element, item) }.freeze
        elsif kind == :map && value.is_a?(Hash)
          value.to_h { |key, item| [key.to_s, coerce(element, item)] }.freeze
        else
          plain(value)
        end
      end

      # Compares the declared properties of a decoded top-level model with the JSON it came from.
      #
      # @param model [Object] the result of {coerce}; anything but a model is not checked
      # @param data [Hash] the JSON object as parsed
      # @return [String, nil] what is wrong with the first property of the wrong kind; the value
      #   itself is never quoted, it may be a secret
      def mismatch(model, data)
        return nil unless model.is_a?(Tungo::Model) && data.is_a?(Hash)

        model.class.fields.each_value do |field|
          value = data[field.api_name]
          expected = value.nil? ? nil : unexpected(field.type, value)
          next unless expected

          return "the property #{field.api_name.inspect} of #{model.class.name.split("::").last} must be " \
                 "#{expected}, got #{json_kind(value)}"
        end
        nil
      end

      # @return [String, nil] the kind the spec demands when the value is of another kind
      def unexpected(spec, value)
        case spec
        when :string then "a string" unless value.is_a?(String)
        when :integer then "an integer" unless integral?(value)
        when :number then "a number" unless value.is_a?(Numeric)
        when :boolean then "a boolean" unless [true, false].include?(value)
        when Array then unexpected_collection(spec.first, value)
        when Symbol then PRIMITIVES.include?(spec) ? nil : unexpected_named(Tungo::Models.const_get(spec), value)
        end
      end

      def unexpected_collection(kind, value)
        if kind == :array
          "an array" unless value.is_a?(Array)
        elsif kind == :map
          "an object" unless value.is_a?(Hash)
        end
      end

      # A model is an object, an enumeration is a scalar, an alias is what it names; a union is
      # not checked.
      def unexpected_named(const, value)
        case const
        when Class then "an object" unless value.is_a?(Hash)
        when Enum then "a string or a number" if value.is_a?(Hash) || value.is_a?(Array)
        when Alias then unexpected(const.target, value)
        end
      end

      def integral?(value)
        value.is_a?(Integer) || (value.is_a?(BigDecimal) && value.finite? && value.frac.zero?)
      end

      def json_kind(value)
        case value
        when Hash then "an object"
        when Array then "an array"
        when String then "a string"
        when Numeric then "a number"
        else "a boolean"
        end
      end

      # Turns an arbitrary value into frozen JSON-like data without assigning it a type.
      def plain(value)
        case value
        when Hash then value.to_h { |key, item| [key.to_s, plain(item)] }.freeze
        when Array then value.map { |item| plain(item) }.freeze
        when Symbol then value.to_s
        when String then value.frozen? ? value : value.dup.freeze
        else value
        end
      end

      # Renders a typed value as JSON-ready data (string keys, no model objects).
      def wire(value)
        case value
        when Tungo::Model then value.to_wire
        when Hash then value.to_h { |key, item| [key.to_s, wire(item)] }
        when Array then value.map { |item| wire(item) }
        when Symbol then value.to_s
        when Time, Date then Util.scalar_text(value)
        else value
        end
      end

      # Renders a typed value as plain Ruby data with symbol keys.
      def ruby(value)
        case value
        when Tungo::Model then value.to_h
        when Hash then value.to_h { |key, item| [key.to_sym, ruby(item)] }
        when Array then value.map { |item| ruby(item) }
        else value
        end
      end
    end

    # Builders of container type specs, available inside generated model, union and alias bodies.
    module Specs
      module_function

      # @return [Array] the spec of an array whose elements have the given spec
      def array_of(element)
        [:array, element].freeze
      end

      # @return [Array] the spec of an object with arbitrary keys whose values have the given spec
      def map_of(element)
        [:map, element].freeze
      end
    end

    # Behaviour of a generated enumeration module. The values are plain strings (or numbers):
    # a value this SDK version does not know is passed through unchanged.
    module Enum
      # @return [Array] every value known to this SDK version
      def values
        @values ||= constants(false).map { |name| const_get(name) }.freeze
      end

      # @return [Boolean] whether the value is known to this SDK version
      def known?(value)
        values.include?(value.is_a?(Symbol) ? value.to_s : value)
      end

      # @api private
      def coerce(value)
        Type.plain(value)
      end
    end

    # Behaviour of a generated union module: +coerce+ picks the variant a JSON value belongs to.
    module Union
      include Specs

      # @api private
      def discriminated_by(property, mapping)
        @discriminator = property
        @mapping = mapping.freeze
      end

      # @api private
      def variants(*specs)
        @variants = specs.freeze unless specs.empty?
        @variants || []
      end

      # @return [String, nil] the JSON property that selects the variant
      attr_reader :discriminator

      # @return [Hash{String=>Class}] discriminator value => model class
      def mapping
        (@mapping || {}).transform_values { |name| Tungo::Models.const_get(name) }
      end

      # @return [Object] a model of one of the variants, {Tungo::UnknownVariant} for an object
      #   that matches none of them, or the value itself for primitives
      def coerce(value)
        case value
        when Tungo::Model then value
        when Hash then coerce_object(value.transform_keys(&:to_s))
        when Array then coerce_array(value)
        else Type.plain(value)
        end
      end

      private

      def coerce_object(data)
        klass = @discriminator ? tagged_class(data) : structural_class(data)
        (klass || Tungo::UnknownVariant).from_wire(data)
      end

      def tagged_class(data)
        name = (@mapping || {})[data[@discriminator].to_s] unless data[@discriminator].nil?
        name && Tungo::Models.const_get(name)
      end

      # Without a discriminator the variant is the one whose required properties are all present;
      # among several, the one that recognises the most properties.
      def structural_class(data)
        candidates = model_variants.select { |klass| klass.required_api_names.all? { |name| data.key?(name) } }
        candidates.max_by { |klass| data.count { |name, _| klass.fields.key?(name) } }
      end

      def model_variants
        variants.grep(Symbol).reject { |spec| Type::PRIMITIVES.include?(spec) }
                .map { |spec| Tungo::Models.const_get(spec) }
                .select { |const| const.is_a?(Class) && const <= Tungo::Model }
      end

      def coerce_array(value)
        spec = variants.find { |candidate| candidate.is_a?(Array) && candidate.first == :array }
        spec ? Type.coerce(spec, value) : Type.plain(value)
      end
    end

    # Behaviour of a generated alias module: a name for another type.
    module Alias
      include Specs

      # @api private
      def target(spec = nil)
        @target = spec unless spec.nil?
        @target
      end

      # @api private
      def coerce(value)
        Type.coerce(@target, value)
      end
    end
  end

  # Base class of every generated model: an immutable value object with typed readers.
  #
  # * Fields the SDK does not know are retained and available through {#[]} and {#to_h}.
  # * +nil+ and "absent" are different: {#key?} tells whether the property is present. A model
  #   built with +name: nil+ serialises +"name": null+; a model built without +name+ omits it.
  # * Models are frozen. {#with} returns a changed copy.
  class Model
    # Describes one declared property.
    Field = Data.define(:name, :api_name, :type, :required, :nullable)

    class << self
      include Internal::Specs

      # @return [Hash{String=>Field}] declared properties by wire name
      def fields
        @fields ||= {}
      end

      # @return [Array<String>] wire names of the required properties
      def required_api_names
        @required_api_names ||= fields.values.select(&:required).map(&:api_name).freeze
      end

      # @return [Object, nil] type spec of additional properties, when the contract declares one
      attr_reader :extra_type

      # @return [Array<String>] wire names of the properties that hold credentials; {#inspect} hides their values
      def sensitive_api_names
        @sensitive_api_names || []
      end

      # Builds a model from a decoded JSON object (string or symbol keys).
      #
      # @param data [Hash]
      # @return [Tungo::Model]
      def from_wire(data, api_response: nil)
        instance = allocate
        instance.send(:load_attributes, data, api_response)
        instance
      end

      # @api private
      def coerce(value)
        case value
        when Tungo::Model then value
        when Hash then from_wire(value)
        else Internal::Type.plain(value)
        end
      end

      # @api private
      def api_name_for(key)
        key = key.to_s
        (@reader_names ||= {})[key] || key
      end

      private

      def sensitive(*api_names)
        @sensitive_api_names = api_names.map(&:to_s).freeze
      end

      def required(name, type, api_name: name.to_s, nullable: false)
        declare(name, type, api_name, true, nullable)
      end

      def optional(name, type, api_name: name.to_s, nullable: false)
        declare(name, type, api_name, false, nullable)
      end

      def additional_properties(type)
        @extra_type = type
      end

      def declare(name, type, api_name, required, nullable)
        fields[api_name] = Field.new(name: name, api_name: api_name, type: type, required: required, nullable: nullable)
        (@reader_names ||= {})[name.to_s] = api_name
        define_method(name) { @data[api_name] }
      end
    end

    # @param attributes [Hash] properties by reader name or wire name; {Tungo::OMIT} values are skipped
    def initialize(**attributes)
      load_attributes(attributes, nil)
    end

    # @return [Tungo::APIResponse, nil] status and headers of the HTTP response this object was
    #   decoded from; nil for nested and hand-built objects
    attr_reader :api_response

    # Reads a property by reader name or wire name, including properties unknown to this SDK version.
    def [](name)
      @data[self.class.api_name_for(name)]
    end

    # @return [Boolean] whether the property is present (even when its value is nil)
    def key?(name)
      @data.key?(self.class.api_name_for(name))
    end

    # @return [Hash{Symbol=>Object}] the properties as plain Ruby data, nested models included
    def to_h
      @data.to_h { |name, value| [name.to_sym, Internal::Type.ruby(value)] }
    end

    # @return [Hash{String=>Object}] the properties exactly as they travel in JSON
    def to_wire
      @data.transform_values { |value| Internal::Type.wire(value) }
    end

    def to_json(*)
      Internal::Util.generate_json(to_wire)
    end

    # @return [Tungo::Model] a copy with the given properties replaced
    def with(**changes)
      self.class.new(**@data, **changes.transform_keys { |key| self.class.api_name_for(key) })
    end

    def ==(other)
      other.class == self.class && other.to_wire == to_wire
    end
    alias eql? ==

    def hash
      [self.class, to_wire].hash
    end

    def deconstruct_keys(_keys)
      to_h
    end

    # A credential (an API key, a signing secret, a hook token) is shown as [REDACTED].
    def inspect
      hidden = self.class.sensitive_api_names
      shown = @data.map do |name, value|
        text = hidden.include?(name) && !value.nil? ? "[REDACTED]" : value.inspect
        "#{name}=#{text}"
      end
      "#<#{self.class.name} #{shown.join(" ")}>"
    end
    alias to_s inspect

    def pretty_print(printer)
      printer.text(inspect)
    end

    # @api private
    def with_api_response(api_response)
      self.class.from_wire(@data, api_response: api_response)
    end

    private

    def load_attributes(attributes, api_response)
      data = {}
      attributes.each do |key, value|
        next if OMIT.equal?(value)

        api_name = self.class.api_name_for(key)
        field = self.class.fields[api_name]
        data[api_name] = Internal::Type.coerce(field ? field.type : self.class.extra_type, value)
      end
      @data = data.freeze
      @api_response = api_response
      freeze
    end
  end

  # A union member this SDK version does not know: an object whose discriminator value is new,
  # or whose shape matches no known variant. Every property is retained ({Tungo::Model#[]},
  # {Tungo::Model#to_h}).
  class UnknownVariant < Model; end
end

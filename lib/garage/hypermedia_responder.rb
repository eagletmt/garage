require 'oj'

module Garage
  module HypermediaResponder
    ESCAPE_JSON = { '<' => '\u003C', '>' => '\u003E' }.freeze

    def display(resource, given_options={})
      given_options[:content_type] = representation.content_type if representation.dictionary?
      if @options[:cacheable_with]
        delegate = Garage::CacheableListDelegate.new(resource, @options[:cacheable_with])
        representation = maybe_cache(delegate, controller.field_selector) {
          transform(resource)
        }
        super(render(representation), given_options)
      else
        super(render(transform(resource)), given_options)
      end
    end

    def render(data)
      if representation.dictionary?
        data = render_dict(data)
      end

      if representation.msgpack?
        data.to_msgpack
      else
        # default to JSON
        encode_json_safe(data)
      end
    end

    def render_dict(data)
      # might be prettier to check respond_to? etc. but at this point the data is
      # serialized down to the lowest level structure (Array/Hash)
      if data.is_a?(Array) && (data.empty? || data.first.respond_to?(:[]))
        data.index_by {|entry| entry['id'] }
      end
      # TODO else 400?
    end

    def transform(resource)
      if resource.respond_to?(:map)
        resource.map {|r| encode_to_hash(r, partial: true, selector: controller.field_selector) }
      else
        encode_to_hash(resource, selector: controller.field_selector)
      end
    end

    def encode_json_safe(doc)
      Oj.dump(doc, :mode => :compat).gsub(/([<>])/) {|c| ESCAPE_JSON[c] }
    end

    def encode_to_hash(resource, *args)
      if resource.respond_to?(:id)
        cache_key = "#{resource.class.name}:#{resource.id}"
        cache[cache_key] ||= _encode_to_hash(resource, *args)
      else
        _encode_to_hash(resource, *args)
      end
    end

  private

    def _encode_to_hash(resource, options = {})
      resource.represent!
      resource.default_url_options = {}
      resource.partial = options[:partial]
      resource.selector = options[:selector]
      maybe_cache(resource, options[:selector]) { resource.to_hash(:responder => self) }
    end

    def maybe_cache(resource, selector, &blk)
      if resource.cacheable? && resource.respond_to?(:cache_key) &&
          /no-cache/ !~ controller.request.headers['Cache-Control']
        key = cache_key_for(resource, selector)
        cached = true
        Rails.cache.fetch(key) {
          cached = false
          blk.call
        }.tap do
          if cached
            Rails.logger.info "Responder Cache HIT: #{key}"
            controller.response.headers['X-Garage-Cache'] = Rack::Utils.build_query(key)
          end
        end
      else
        blk.call
      end
    end

    def cache_key_for(resource, selector)
      hash = controller.cache_context.merge(r: resource.cache_key)
      hash[:s] = selector.canonical if selector
      hash
    end

    def cache
      @cache ||= {}
    end

    def representation
      @representation ||= Representation.new(controller)
    end

    class Representation
      attr_reader :controller

      def initialize(controller)
        @controller = controller
      end

      def dictionary?
        controller.representation == :dictionary
      end

      def msgpack?
        controller.request.format.to_sym == :msgpack
      end

      def content_type
        mime, payload = controller.request.format.to_s.split("/", 2)
        "#{mime}/vnd.cookpad.dictionary+#{payload}"
      end
    end
  end
end

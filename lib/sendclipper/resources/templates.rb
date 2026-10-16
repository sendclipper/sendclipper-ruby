# frozen_string_literal: true

module SendClipper
  module Resources
    class Templates < Base
      attr_reader :tags, :assets

      def initialize(http)
        super
        @tags = TemplateTags.new(http)
        @assets = TemplateAssets.new(http)
      end

      # Fields: tag (a tag id), project (a domain id).
      def list(params = nil, **kw)
        query, options = split(params, kw)
        api_get("/templates", query: query, options: options)
      end

      # By uuid or public id (+tpl_...+).
      def get(id, **options) = api_get("/templates/#{seg(id)}", options: options)

      # The rendered HTML, tags left in place.
      def html(id, **options) = @http.call("GET", "/templates/#{seg(id)}/html", as: :text, options: options)

      # A new draft. Publish it before sending with it. Fields: name, subject,
      # preheader, blocks, project_domain_id, key.
      def create(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/templates", body, options: options)
      end

      def update(id, params = nil, **kw)
        body, options = split(params, kw)
        api_patch("/templates/#{seg(id)}", body, options: options)
      end

      def remove(id, **options) = api_delete("/templates/#{seg(id)}", options: options)

      def duplicate(id, **options) = api_post("/templates/#{seg(id)}/duplicate", nil, options: options)

      def publish(id, **options) = api_post("/templates/#{seg(id)}/publish", nil, options: options)

      def unpublish(id, **options) = api_post("/templates/#{seg(id)}/unpublish", nil, options: options)

      # Render with +variables+ without sending anything.
      def preview(id, variables = {}, **options)
        api_post("/templates/#{seg(id)}/preview", { "variables" => variables.to_h }, options: options)
      end

      # Replace the template's tags with these tag ids.
      def set_tags(id, tag_ids, **options) = api_put("/templates/#{seg(id)}/tags", { "tagIds" => tag_ids.to_a }, options: options)

      # The projects (domains) templates can belong to.
      def projects(**options) = api_get("/templates/projects", options: options)
    end

    class TemplateTags < Base
      # Every tag, each with its templateCount.
      def list(**options) = api_get("/templates/tags", options: options)

      # Fields: name, color (gray, red, orange, amber, green, teal, blue, purple, pink).
      def create(params = nil, **kw)
        body, options = split(params, kw)
        api_post("/templates/tags", body, options: options)
      end

      def update(id, params = nil, **kw)
        body, options = split(params, kw)
        api_patch("/templates/tags/#{seg(id)}", body, options: options)
      end

      # { "deleted" => true, "templateCount" => n }: the tag is taken off n templates.
      def remove(id, **options) = api_delete("/templates/tags/#{seg(id)}", options: options)
    end

    class TemplateAssets < Base
      def list(**options) = api_get("/templates/assets", options: options)

      # Upload an image a template can show and get its public URL. +data:+ is
      # the file's bytes (base64-encoded for you); +mime_type:+ is image/png,
      # image/jpeg, image/gif or image/webp.
      #
      #   client.templates.assets.upload(data: File.binread("logo.png"), mime_type: "image/png", name: "logo")
      def upload(data:, mime_type:, name: nil, **options)
        body = { "mimeType" => mime_type, "base64" => [data.to_s].pack("m0") }
        body["name"] = name if name && !name.empty?
        api_post("/templates/assets", body, options: options)
      end
    end
  end
end

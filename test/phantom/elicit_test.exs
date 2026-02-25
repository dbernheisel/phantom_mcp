defmodule Phantom.ElicitTest do
  use ExUnit.Case, async: true

  alias Phantom.Elicit

  describe "build/1 with enum properties" do
    test "builds titled single-select enum" do
      elicit =
        Elicit.build(%{
          message: "Pick a color",
          requested_schema: [
            %{
              type: :enum,
              name: "color",
              required: true,
              enum: [{"#FF0000", "Red"}, {"#00FF00", "Green"}, {"#0000FF", "Blue"}]
            }
          ]
        })

      [prop] = elicit.requested_schema
      assert prop.type == :enum
      assert prop.enum == [{"#FF0000", "Red"}, {"#00FF00", "Green"}, {"#0000FF", "Blue"}]
    end

    test "builds untitled multi-select enum" do
      elicit =
        Elicit.build(%{
          message: "Pick colors",
          requested_schema: [
            %{
              type: :enum,
              name: "colors",
              required: true,
              enum: ~w[red green blue],
              multi: true,
              min: 1,
              max: 3
            }
          ]
        })

      [prop] = elicit.requested_schema
      assert prop.type == :enum
      assert prop.multi == true
      assert prop.min == 1
      assert prop.max == 3
    end

    test "builds untitled single-select enum" do
      elicit =
        Elicit.build(%{
          message: "Pick a color",
          requested_schema: [
            %{type: :enum, name: "color", required: true, enum: ~w[red green blue]}
          ]
        })

      [prop] = elicit.requested_schema
      assert prop.type == :enum
      assert prop.enum == ~w[red green blue]
      assert prop.name == "color"
      assert prop.required == true
      refute Map.has_key?(prop, :multi)
    end
  end

  describe "to_json/1 with enum properties" do
    test "titled single-select emits type string with oneOf" do
      elicit =
        Elicit.build(%{
          message: "Pick a color",
          requested_schema: [
            %{
              type: :enum,
              name: "color",
              required: true,
              enum: [{"#FF0000", "Red"}, {"#00FF00", "Green"}]
            }
          ]
        })

      json = Elicit.to_json(elicit)
      color = json.requestedSchema.properties["color"]

      assert color.type == "string"

      assert color.oneOf == [
               %{const: "#FF0000", title: "Red"},
               %{const: "#00FF00", title: "Green"}
             ]

      refute Map.has_key?(color, :enum)
      refute Map.has_key?(color, :enumNames)
    end

    test "untitled multi-select emits array with items.enum" do
      elicit =
        Elicit.build(%{
          message: "Pick colors",
          requested_schema: [
            %{
              type: :enum,
              name: "colors",
              required: true,
              enum: ~w[red green blue],
              multi: true,
              min: 1,
              max: 3
            }
          ]
        })

      json = Elicit.to_json(elicit)
      colors = json.requestedSchema.properties["colors"]

      assert colors == %{
               type: "array",
               minItems: 1,
               maxItems: 3,
               items: %{type: "string", enum: ["red", "green", "blue"]}
             }
    end

    test "enum preserves title and description in JSON output" do
      elicit =
        Elicit.build(%{
          message: "Pick a color",
          requested_schema: [
            %{
              type: :enum,
              name: "color",
              required: true,
              title: "Favorite Color",
              description: "Choose one",
              enum: ~w[red green blue]
            }
          ]
        })

      json = Elicit.to_json(elicit)
      color = json.requestedSchema.properties["color"]

      assert color.type == "string"
      assert color.title == "Favorite Color"
      assert color.description == "Choose one"
      assert color.enum == ["red", "green", "blue"]
    end

    test "titled multi-select emits array with items.oneOf" do
      elicit =
        Elicit.build(%{
          message: "Pick colors",
          requested_schema: [
            %{
              type: :enum,
              name: "colors",
              required: true,
              enum: [{"#FF0000", "Red"}, {"#00FF00", "Green"}],
              multi: true,
              min: 1
            }
          ]
        })

      json = Elicit.to_json(elicit)
      colors = json.requestedSchema.properties["colors"]

      assert colors == %{
               type: "array",
               minItems: 1,
               items: %{
                 oneOf: [
                   %{const: "#FF0000", title: "Red"},
                   %{const: "#00FF00", title: "Green"}
                 ]
               }
             }
    end

    test "untitled single-select emits type string with enum array" do
      elicit =
        Elicit.build(%{
          message: "Pick a color",
          requested_schema: [
            %{type: :enum, name: "color", required: true, enum: ~w[red green blue]}
          ]
        })

      json = Elicit.to_json(elicit)
      color = json.requestedSchema.properties["color"]

      assert color == %{type: "string", enum: ["red", "green", "blue"]}
      assert "color" in json.requestedSchema.required
    end
  end

  describe "build/1 with non-enum properties" do
    test "string property still works" do
      elicit =
        Elicit.build(%{
          message: "Enter info",
          requested_schema: [
            %{
              type: :string,
              name: "email",
              required: true,
              title: "Email",
              description: "Your email",
              format: :email
            }
          ]
        })

      json = Elicit.to_json(elicit)
      email = json.requestedSchema.properties["email"]
      assert email.type == :string
      assert email.format == :email
    end

    test "boolean property still works" do
      elicit =
        Elicit.build(%{
          message: "Confirm",
          requested_schema: [
            %{
              type: :boolean,
              name: "agree",
              required: true,
              title: "Agree?",
              description: "Do you agree?",
              default: false
            }
          ]
        })

      json = Elicit.to_json(elicit)
      agree = json.requestedSchema.properties["agree"]
      assert agree.type == :boolean
      assert agree.default == false
    end

    test "number property still works" do
      elicit =
        Elicit.build(%{
          message: "Enter age",
          requested_schema: [
            %{type: :integer, name: "age", required: true, minimum: 0, maximum: 150}
          ]
        })

      json = Elicit.to_json(elicit)
      age = json.requestedSchema.properties["age"]
      assert age.type == :integer
      assert age.minimum == 0
      assert age.maximum == 150
    end
  end

  describe "build/1 with mixed properties" do
    test "builds schema with enum alongside other types" do
      elicit =
        Elicit.build(%{
          message: "Survey",
          requested_schema: [
            %{
              type: :string,
              name: "name",
              required: true,
              title: "Name",
              description: "Your name"
            },
            %{type: :enum, name: "color", required: true, enum: ~w[red green blue]},
            %{
              type: :enum,
              name: "sizes",
              required: false,
              enum: [{"S", "Small"}, {"M", "Medium"}, {"L", "Large"}],
              multi: true,
              min: 1
            },
            %{
              type: :boolean,
              name: "newsletter",
              required: false,
              title: "Subscribe?",
              description: "Get updates",
              default: true
            }
          ]
        })

      json = Elicit.to_json(elicit)
      props = json.requestedSchema.properties

      assert props["color"].type == "string"
      assert props["color"].enum == ["red", "green", "blue"]

      assert props["sizes"].type == "array"
      assert props["sizes"].minItems == 1

      assert props["name"].type == :string
      assert props["newsletter"].type == :boolean

      assert "name" in json.requestedSchema.required
      assert "color" in json.requestedSchema.required
      refute "newsletter" in json.requestedSchema.required
    end
  end

  describe "form/1" do
    test "is an alias for build/1" do
      attrs = %{
        message: "Hello",
        requested_schema: [%{type: :string, name: "name", required: true}]
      }

      assert Elicit.form(attrs) == Elicit.build(attrs)
    end
  end

  describe "url/1" do
    test "builds URL mode elicitation" do
      elicit =
        Elicit.url(%{
          message: "Please authenticate",
          url: "https://example.com/oauth",
          elicitation_id: "elicit-123"
        })

      assert elicit.mode == :url
      assert elicit.message == "Please authenticate"
      assert elicit.url == "https://example.com/oauth"
      assert elicit.elicitation_id == "elicit-123"
      assert elicit.requested_schema == nil
    end

    test "raises on missing required fields" do
      assert_raise KeyError, fn ->
        Elicit.url(%{message: "Hello"})
      end
    end
  end

  describe "to_json/1 with URL mode" do
    test "emits mode, message, url, and elicitationId" do
      elicit =
        Elicit.url(%{
          message: "Please authenticate",
          url: "https://example.com/oauth",
          elicitation_id: "elicit-456"
        })

      json = Elicit.to_json(elicit)

      assert json == %{
               mode: "url",
               message: "Please authenticate",
               url: "https://example.com/oauth",
               elicitationId: "elicit-456"
             }
    end
  end

  describe "to_json/1 with form mode" do
    test "includes mode field" do
      elicit =
        Elicit.form(%{
          message: "Enter name",
          requested_schema: [%{type: :string, name: "name", required: true}]
        })

      json = Elicit.to_json(elicit)
      assert json.mode == "form"
      assert json.message == "Enter name"
      assert is_map(json.requestedSchema)
    end
  end
end

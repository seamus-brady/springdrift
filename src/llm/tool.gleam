import gleam/list
import gleam/option.{type Option, None, Some}
import llm/types.{
  type ParameterSchema, type Tool, BooleanProperty, IntegerProperty,
  NumberProperty, ParameterSchema, StringProperty, Tool,
}

/// Opaque builder for constructing Tool values via a pipeline API
pub opaque type ToolBuilder {
  ToolBuilder(
    name: String,
    description: Option(String),
    params: List(#(String, ParameterSchema)),
    required: List(String),
  )
}

/// Create a new ToolBuilder with the given tool name
pub fn new(name: String) -> ToolBuilder {
  ToolBuilder(name: name, description: None, params: [], required: [])
}

/// Set a human-readable description for the tool
pub fn with_description(
  builder: ToolBuilder,
  description: String,
) -> ToolBuilder {
  ToolBuilder(..builder, description: Some(description))
}

fn add_param_internal(
  builder: ToolBuilder,
  param_name: String,
  schema: ParameterSchema,
  is_required: Bool,
) -> ToolBuilder {
  let new_params = list.append(builder.params, [#(param_name, schema)])
  let new_required = case is_required {
    True -> list.append(builder.required, [param_name])
    False -> builder.required
  }
  ToolBuilder(..builder, params: new_params, required: new_required)
}

/// Add a string parameter
pub fn add_string_param(
  builder: ToolBuilder,
  param_name: String,
  description: String,
  is_required: Bool,
) -> ToolBuilder {
  let schema =
    ParameterSchema(
      param_type: StringProperty,
      description: Some(description),
      enum_values: None,
    )
  add_param_internal(builder, param_name, schema, is_required)
}

/// Add a number (float) parameter
pub fn add_number_param(
  builder: ToolBuilder,
  param_name: String,
  description: String,
  is_required: Bool,
) -> ToolBuilder {
  let schema =
    ParameterSchema(
      param_type: NumberProperty,
      description: Some(description),
      enum_values: None,
    )
  add_param_internal(builder, param_name, schema, is_required)
}

/// Add an integer parameter
pub fn add_integer_param(
  builder: ToolBuilder,
  param_name: String,
  description: String,
  is_required: Bool,
) -> ToolBuilder {
  let schema =
    ParameterSchema(
      param_type: IntegerProperty,
      description: Some(description),
      enum_values: None,
    )
  add_param_internal(builder, param_name, schema, is_required)
}

/// Add a boolean parameter
pub fn add_boolean_param(
  builder: ToolBuilder,
  param_name: String,
  description: String,
  is_required: Bool,
) -> ToolBuilder {
  let schema =
    ParameterSchema(
      param_type: BooleanProperty,
      description: Some(description),
      enum_values: None,
    )
  add_param_internal(builder, param_name, schema, is_required)
}

/// Add an enum (string with allowed values) parameter
pub fn add_enum_param(
  builder: ToolBuilder,
  param_name: String,
  description: String,
  values: List(String),
  is_required: Bool,
) -> ToolBuilder {
  let schema =
    ParameterSchema(
      param_type: StringProperty,
      description: Some(description),
      enum_values: Some(values),
    )
  add_param_internal(builder, param_name, schema, is_required)
}

/// Add a parameter with a fully custom ParameterSchema
pub fn add_param(
  builder: ToolBuilder,
  param_name: String,
  schema: ParameterSchema,
  is_required: Bool,
) -> ToolBuilder {
  add_param_internal(builder, param_name, schema, is_required)
}

/// Finalise the builder and produce a Tool
pub fn build(builder: ToolBuilder) -> Tool {
  Tool(
    name: builder.name,
    description: builder.description,
    parameters: builder.params,
    required_params: builder.required,
  )
}

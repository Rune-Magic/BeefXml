using System;
using System.Collections;
using System.Diagnostics;
using System.Globalization;

using Regex;

namespace Json;

class JsonSchema
{
	Type type;
	List<JsonElement> enumeration;

	String title, description;
	JsonElement? defaultValue, constValue;
	List<JsonElement> examples;
	bool deprecated, readOnly, writeOnly;

	List<JsonSchema> anyOf, allOf, oneOf;
	JsonSchema not, _if, _then, _else;

	// string
	RegexTreeNode pattern;
	int? minLength, maxLength;
	StringFormat format;

	// number
	double? dMultipleOf, dMin, dMax;
	bool minExclusive, maxExclusive;

	/// integer
	int? iMultipleOf, iMin, iMax;

	// object
	Dictionary<String, JsonSchema> properties; List<String> required;
	Dictionary<RegexTreeNode, JsonSchema> patternProperties;
	JsonSchema additionalProperties, unevaluatedProperties, propertyNames;
	Dictionary<String, List<String>> dependentRequired;
	Dictionary<String, JsonSchema> dependentSchemas;
	int? minProperties, maxProperties;

	// array
	JsonSchema items; List<JsonSchema> prefixItems;
	JsonSchema unevaluatedItems, contains;
	int? minContains, maxContains;
	int? minItems, maxItems;
	bool uniqueItems;

	public enum Type
	{
		__Pass = default,
		__AlwaysFail, __AlwaysSucceed,

		string,
		number,
		integer,
		object,
		array,
		boolean,
		@null,
	}

	public enum StringFormat
	{
		__None = default,
		dateTime, time, date, duration,
		email, idn_email,
		hostname, idn_hostname,
		ipv4, ipv6,
		uuid, regex,
		uri, uri_reference,
		iri, iri_reference,
		json_pointer, relative_json_pointer,
	}

	public void CopyTo(JsonSchema to)
	{
		Internal.MemCpy(Internal.UnsafeCastToPtr(to), Internal.UnsafeCastToPtr(this), sizeof(Self), alignof(Self));
	}

	public static Result<Self> Parse(JsonReader reader, ITypedAllocator alloc)
	{
		Result<void> Assert(bool condition, StringView err, params Object[] args)
		{
			if (!condition)
			{
				reader.Error(err, params args);
				return .Err;
			}
			return .Ok;
		}

		Self result = new:alloc .();
		switch (Try!(reader.NextToken()))
		{
		case .True: result.type = .__AlwaysSucceed;
		case .False: result.type = .__AlwaysFail;
		case .LSquirly:
			HashSet<String> keys = scope .();
			Try!(Assert(Try!(reader.NextToken()) case .String(let key), "Expected key"));
			Try!(Assert(keys.Add(key), "Duplicate key"));
			Try!(Assert(Try!(reader.NextToken()) case .Colon, "Expected ':'"));
			switch (key)
			{
			case "type":
			}
		default:
			reader.Error("Expected boolean or object");
			return .Err;
		}
		return result;
	}
}

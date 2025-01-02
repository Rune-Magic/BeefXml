using Xml;
using System;
using System.IO;
using System.Collections;

namespace Json;

typealias MarkupSource = Xml.MarkupSource;

enum JsonToken
{
	case True, False, Null;
	case RSquirly, LSquirly;
	case RBracket, LBracket;
	case Comma, Colon, EOF;
	case String(String string);
	case Int(int64), Float(double);
}

enum JsonElement
{
	case Int(int64), Float(double), String(String), Bool(bool), Null;
	case Array(List<JsonElement>), Object(Dictionary<String, JsonElement>);

	public static operator JsonElement (String lhs) => lhs == null ? .Null : .String(lhs);
	public static operator JsonElement (bool lhs) => .Bool(lhs);
	public static operator JsonElement (int lhs) => .Int(lhs);
	public static operator JsonElement (double lhs) => .Float(lhs);

	public ref JsonElement this[int idx]
	{
		get
		{
			Runtime.Assert(this case .Array(let array));
			return ref array[idx];
		}

		set
		{
			Runtime.Assert(this case .Array(let array));
			array[idx] = value;
		}
	}

	public ref JsonElement this[String key]
	{
		get
		{
			Runtime.Assert(this case .Object(let object));
			return ref object[key];
		}

		set
		{
			Runtime.Assert(this case .Object(let object));
			object[key] = value;
		}
	}
}

static class Json
{
	public static mixin Open(StringView fileName, JsonReader.Options flags = default)
	{
		StreamReader stream = scope:mixin .();
		stream.Open(fileName) case .Err(let err)
			? Result<JsonReader, FileOpenError>.Err(err)
			: Result<JsonReader, FileOpenError>.Ok(
				scope:mixin .(scope:mixin .(stream, fileName), flags)
			)
	}
}
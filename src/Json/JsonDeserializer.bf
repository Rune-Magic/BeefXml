using System;
using System.Collections;
using System.Diagnostics;

using Json;
using internal Json;

namespace Json;

typealias NoSerializeAttribute = Xml.NoSerializeAttribute;
typealias ForceSerializeAttribute = Xml.ForceSerializeAttribute;

interface IJsonSerializeable
{
	public Result<void> Serialize(JsonBuilder builder);
	public static Result<Self> Deserialize(JsonReader reader);
	public void WriteSchema(String outString);
}

extension Json
{
	public static Result<T> Deserialize<T>(JsonReader reader) where T : IJsonSerializeable
	{
		return T.Deserialize(reader);
	}

	public static Result<T> Deserialize<T>(JsonReader reader, bool requireAll = true)
	{
		mixin Assert(bool condition, StringView err)
		{
			if (!condition)
			{
				reader.Error(err);
				return .Err;
			}
		}

		[Comptime, NoReturn]
		void Emit<T>()
		{
			if (typeof(T).IsGenericParam) return;
			String error = scope .("Unable to generate deserialization code for type: ");
			typeof(T).GetFullName(error);
			Runtime.FatalError(error);
		}

		[Comptime, NoReturn]
		void Emit<T>() where T : class
		{
			let type = typeof(T);
			String outString = scope .(256);
			outString.Append("""
				var next = Try!(reader.NextToken());
				if (next case .Null) return .Ok(null);
				Assert!(next case .LSquirly, \"Expected object\");
				T result = new:(reader.alloc) .();
				""");
			if (type.FieldCount == 0)
			{
				Compiler.MixinRoot(outString);
				return;
			}
			outString.Append("""
				loop: while (true)
				{
					Assert!(next case .String(let key), \"Expected object\");
					switch (key)
					{
				""");

			String check = scope .(256);
			for (let field in type.GetFields())
			{
				if (!field.HasCustomAttribute<ForceSerializeAttribute>())
					if (field.IsConst || field.IsStatic || !field.IsPublic || field.HasCustomAttribute<NoSerializeAttribute>())
						continue;
				let name = field.Name;
				outString.AppendF($"""
					case "{name}":
						Assert(!{name}, "Duplicate key");
						Assert!(next case .Colon, \"Expected colon\");
						result.{name} = Deserialize<decltype(result.{name})>(reader);
						{name} = true;
					""");
				outString.Insert(0, scope $"bool {name} = false;\n");
				check.AppendF($"\tAssert!({name}, \"Missing field '{name}'\")\n");
			}

			outString.Append($$"""
					default:
						reader.Error("Unexpected entry '{key}'");
						return .Err;
					}
					switch (Try!(reader.NextToken()))
					{
					case .Comma:
					case .RSquirly: break loop;
					default:
						reader.Error("Expected ',' or '}'");
					}
				}

				if (requireAll)
				{
				{{check}}}
				return result;
				""");
		}

		Emit<T>();
	}
}

namespace System;

extension Int : IJsonSerializeable 
{
	public Result<void> Serialize(Json.JsonBuilder builder)
		=> builder.Write(JsonToken.Int((.)this));

	public static System.Result<Self> Deserialize(Json.JsonReader reader)
	{
		var next = Try!(reader.NextToken());
		switch (next)
		{
		case .Int(let p0): return .Ok((.)p0);
		default:
			reader.Error("Expected integer");
			return .Err;
		}
	}

	public void WriteSchema(System.String outString)
		=> outString.Append("{ \"type\": \"integer\" }");
}

extension Double : IJsonSerializeable 
{
	public Result<void> Serialize(Json.JsonBuilder builder)
		=> builder.Write(JsonToken.Number((.)this));

	public static System.Result<Self> Deserialize(Json.JsonReader reader)
	{
		var next = Try!(reader.NextToken());
		switch (next)
		{
		case .Number(let p0): return .Ok((.)p0);
		default:
			reader.Error("Expected number");
			return .Err;
		}
	}

	public void WriteSchema(System.String outString)
		=> outString.Append("{ \"type\": \"number\" }");
}

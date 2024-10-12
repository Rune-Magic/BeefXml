using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Xml;

extension Xml
{
	static mixin Expect(XmlReader reader, XmlVisitable expected)
	{
		if (!(Try!(reader.ParseNext()) case expected))
		{
			reader.Error($"Expected {expected}");
			return .Err;
		}
	}

	static mixin Assert(XmlReader reader, bool condition, StringView errorMsg)
	{
		if (!condition)
		{
			reader.Error(errorMsg);
			return .Err;
		}
	}

	private static Result<void> DoDeserialize<T>(XmlReader reader) where T : void
	{
		return .Ok;
	}

	[Comptime, NoReturn]
	private static void EmitDoDeserializeString()
	{
		Compiler.MixinRoot("""
			Expect!(reader, XmlVisitable.OpeningEnd(false));
			let cdata = Try!(reader.ParseNext());
			Assert!(reader, cdata case .CharacterData(let data), "Expected character data");
			return DoDeserializeString<T>(data, reader);
			""");
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : ICharacter, operator explicit char8, operator explicit char16, operator explicit char32, struct => EmitDoDeserializeString();
	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : IParseable<T> => EmitDoDeserializeString();
	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : String => EmitDoDeserializeString();
	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : StringView => EmitDoDeserializeString();

	private static Result<T> DoDeserializeString<T>(String data, XmlReader reader) where T : ICharacter, operator explicit char8, operator explicit char16, operator explicit char32
	{
		Assert!(reader, data.Length == 1, "Expected single character");
		return .Ok((.)Try!(data.DecodedChars.GetNext()));
	}

	private static Result<T> DoDeserializeString<T>(String data, XmlReader reader) where T : IParseable<T>
	{
		Assert!(reader, T.Parse(data) case .Ok(let val), "Malformed input");
		return .Ok(val);
	}

	private static Result<T> DoDeserializeString<T>(String data, XmlReader reader) where T : String
	{
		return .Ok(data);
	}

	private static Result<T> DoDeserializeString<T>(String data, XmlReader reader) where T : StringView
	{
		return .Ok(data);
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : IXmlSerializable
	{
		return T.Deserialize(reader);
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : void* where T.UnderlyingType : void
	{
		Internal.FatalError("Cannot DoDeserialize void*");
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : struct*
	{
		T.UnderlyingType* result = new:(reader.[Friend]alloc) .();
		(*result) = DoDeserialize<T.UnderlyingType>(reader);
		return result;
	}

	[Comptime]
	static void EmitFieldFill<T>()
	{
		if (typeof(T).IsGenericParam) return;
		String outString = scope .(256);
		String symbols = scope .(256);
		String symbolsCheck = scope .(256);
		outString.Append("""
			XmlVisitable next = ?;
			master: do
			{
				while (true)
				{
					next = Try!(reader.ParseNext());
			
					switch (next)
					{
					case .OpeningEnd(true):
						break master;
					case .OpeningEnd(false):
						break;

			""");
		for (let field in typeof(T).GetFields())
		{
			if (field.IsStatic || field.IsConst || field.HasCustomAttribute<XmlNoSerializeAttribute>()
				|| (!field.IsPublic && !field.HasCustomAttribute<XmlForceSerializeAttribute>())
				|| !field.HasCustomAttribute<XmlAttributeSerializeAttribute>()) continue;

			symbols.AppendF($"bool {field.Name} = false;\n");
			symbolsCheck.AppendF($"Assert!(reader, {field.Name}, \"{typeof(T)}.{field.Name} not found\");\n");
			outString.AppendF($"""
						case .Attribute("{field.Name}", let value):
							Assert!(reader, !{field.Name}, "{typeof(T)}.{field.Name} already defined");
							result.
				""");
			if (!field.IsPublic) outString.Append("[Friend]");
			outString.AppendF($"""
				{field.Name} = DoDeserializeString<decltype(result.{field.Name})>(value, reader);
						{field.Name} = true;

				""");
		}
		outString.Append("""
					default:
						reader.Error($"Unexpected {next}");
						return .Err;
					}
				}

				while (true)
				{
					next = Try!(reader.ParseNext());
		
					switch (next)
					{
					case .ClosingTag:
						reader.Cycle(next);
						break;

			""");
		for (let field in typeof(T).GetFields())
		{
			if (field.IsStatic || field.IsConst || field.HasCustomAttribute<XmlNoSerializeAttribute>()
				|| (!field.IsPublic && !field.HasCustomAttribute<XmlForceSerializeAttribute>())
				|| field.HasCustomAttribute<XmlAttributeSerializeAttribute>()) continue;

			symbols.AppendF($"bool {field.Name} = false;\n");
			symbolsCheck.AppendF($"Assert!(reader, {field.Name}, \"{typeof(T)}.{field.Name} not found\");\n");
			outString.AppendF($"""
						case .OpeningTag("{field.Name}"):
							Assert!(reader, !{field.Name}, "{typeof(T)}.{field.Name} already defined");
							result.
				""");
			if (!field.IsPublic) outString.Append("[Friend]");
			outString.AppendF($"""
				{field.Name} = DoDeserialize<decltype(result.{field.Name})>(reader);
							{field.Name} = true;
							next = Try!(reader.ParseNext());
							switch (next)
							{{
							case .ClosingTag("{field.Name}"):
							case .OpeningEnd(true):
							default:
								reader.Error($"Unexpected {{next}}");
								return .Err;
							}}

				""");
		}
		outString.Append("""
					default:
						reader.Error($"Unexpected {next}");
						return .Err;
					}
				}
			}


			""");
		symbols.Append(outString, symbolsCheck);
		Compiler.MixinRoot(symbols);
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : new, class
	{
		T result = new:(reader.[Friend]alloc) .();
		EmitFieldFill<T>();
		return result;
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : enum
	{
		T result = default;
		var next = Try!(reader.ParseNext());
		Assert!(reader, next case .Attribute("value", let value), "Expected enum value");
		Expect!(reader, XmlVisitable.OpeningEnd(true));
		[Comptime]
		void Emit()
		{
			if (typeof(T).IsGenericParam) return;
			String outString = scope .(256);
			String fields = scope .(256);
			String fieldsDefine = scope .(64);
			String fieldsCheck = scope .(64);
			String result = scope .(32);
			outString.Append("switch (value)\n{\n");
			int i = -1;
			for (let enumcase in typeof(T).GetFields())
			{
				i++;
				if (!enumcase.IsEnumCase) continue;
				outString.AppendF($"""
					case "{enumcase.Name}":

					""");
				fields.Clear();
				bool singleton = true;
				for (let field in enumcase.FieldType.GetFields())
				{
					singleton = singleton && field.FieldType == typeof(void);
					if (singleton) continue;
					fieldsDefine.AppendF($"{field.FieldType} _{field.Name} = ?; bool __{field.Name}__check = false;\n");
					fieldsCheck.AppendF($"Assert!(reader, __{field.Name}__check, \"{typeof(T)}.{field.Name} not found\");\n");
					result.AppendF($"_{field.Name}, ");
					fields.AppendF($"""
							case .OpeningTag("Other{i}"):
								Assert!(reader, !__{field.Name}__check, \"{typeof(T)}.{field.Name} already defined\");
								_{field.Name} = DoDeserialize<{field.FieldType}>(reader);
								__{field.Name}__check = true;

						""");
				}
				if (singleton)
				{
					outString.AppendF($"""
							result = .{enumcase.Name};

						""");
					continue;
				}

				result.RemoveFromEnd(2);
				outString.Append(fieldsDefine, """
						Expect!(reader, XmlVisitable.OpeningEnd(false));
						while (true)
						{
							next = Try!(reader.ParseNext());
							switch (next)
							{

					""", fields, """
							default:
								reader.Error($"Unexpected {next}");
								return .Err;
							}
						}

					""", fieldsCheck,
					"\nresult = .", scope .(enumcase.Name), "(", result, ");\n");
			}
			outString.Append("""
				default:
					reader.Error($"Unexpected {next}");
					return .Err;
				}
				""");
			Compiler.MixinRoot(outString);
		}
		Emit();
		return result;
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) //where T : struct
	{
		Compiler.Assert(typeof(T).[ConstEval]IsValueType || typeof(T).[ConstEval]IsGenericParam);
		T result = default;
		EmitFieldFill<T>();
		return result;
	}

	public static Result<T> Deserialize<T>(XmlReader reader)
	{
		Try!(reader.ParseHeader());
		let root = Try!(reader.ParseNext(true));
		const String name = typeof(T).GetName(..scope .());
		Assert!(reader, root case .OpeningTag(name), String.ConstF($"Expected element {name}"));
		let result = Try!(DoDeserialize<T>(reader));
		Assert!(reader, root case .ClosingTag(name), String.ConstF($"Expected closing tag for {name}"));
		return result;
	}
}

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

	private static mixin DoDeserializeString(XmlReader reader)
	{
		Expect!(reader, XmlVisitable.OpeningEnd(false));
		let cdata = Try!(reader.ParseNext());
		Assert!(reader, cdata case .CharacterData(let data), "Expected character data");
		data
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : ICharacter, operator explicit char8, operator explicit char16, operator explicit char32, struct => DoDeserializeString<T>(DoDeserializeString!(reader), reader);
	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : IParseable<T> => DoDeserializeString<T>(DoDeserializeString!(reader), reader);
	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : String => DoDeserializeString<T>(DoDeserializeString!(reader), reader);
	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : StringView => DoDeserializeString<T>(DoDeserializeString!(reader), reader);

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

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : void*// where T.UnderlyingType : void
	{
		Internal.FatalError("Cannot deserialize void*");
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : new, struct*
	{
		let next = Try!(reader.ParseNext());
		reader.Cycle(next);
		if (next case .OpeningEnd(true))
			return .Ok(null);
		T* result = new:(reader.[Friend]alloc) T();
		*result = Try!(DoDeserialize<decltype(*result)>(reader));
		return .Ok(*result);
	}

	private static Result<TOut?> DoDeserialize<T, TOut>(XmlReader reader) where T : TOut? where TOut : struct
	{
		let next = Try!(reader.ParseNext());
		reader.Cycle(next);
		if (next case .OpeningEnd(true))
			return .Ok(null);
		return Nullable<TOut>(Try!(DoDeserialize<TOut>(reader)));
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
				loop: while (true)
				{
					next = Try!(reader.ParseNext());
			
					switch (next)
					{
					case .OpeningEnd(true):
						reader.Cycle(next);
						break master;
					case .OpeningEnd(false):
						break loop;

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
				{field.Name} = Try!(DoDeserializeString<decltype(result.{field.Name})>(value, reader));
						{field.Name} = true;

				""");
		}
		outString.Append("""
					default:
						reader.Error($"Unexpected {next}");
						return .Err;
					}
				}

				loop: while (true)
				{
					next = Try!(reader.ParseNext());
		
					switch (next)
					{
					case .ClosingTag:
						reader.Cycle(next);
						break loop;

			""");
		for (let field in typeof(T).GetFields())
		{
			if (field.IsStatic || field.IsConst || field.HasCustomAttribute<XmlNoSerializeAttribute>()
				|| (!field.IsPublic && !field.HasCustomAttribute<XmlForceSerializeAttribute>())
				|| field.HasCustomAttribute<XmlAttributeSerializeAttribute>()) continue;

			symbols.AppendF($"bool _{field.Name} = false;\n");
			symbolsCheck.AppendF($"Assert!(reader, _{field.Name}, \"{typeof(T)}.{field.Name} not found\");\n");
			outString.AppendF($"""
						case .OpeningTag("{field.Name}"):
							Assert!(reader, !_{field.Name}, "{typeof(T)}.{field.Name} already defined");
							result.
				""");
			if (!field.IsPublic) outString.Append("[Friend]");
			outString.AppendF($"""
				{field.Name} = Try!(DoDeserialize<decltype(result.{field.Name})>(reader));
							_{field.Name} = true;
							next = Try!(reader.ParseNext());
							Assert!(reader, next case .OpeningEnd(true) || next case .ClosingTag("{field.Name}"), "Expected closing tag for {field.Name}");			

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
		let nullcheck = Try!(reader.ParseNext());
		reader.Cycle(nullcheck);
		if (nullcheck case .OpeningEnd(true))
			return .Ok(null);
		T result = new:(reader.[Friend]alloc) .();
		EmitFieldFill<T>();
		return result;
	}

	private static Result<T> DoDeserialize<T>(XmlReader reader) where T : enum
	{
		T result = default;
		var next = Try!(reader.ParseNext());
		Assert!(reader, next case .Attribute("value", let value), "Expected enum value");
		[Comptime]
		void Emit()
		{
			if (typeof(T).IsGenericParam) return;
			Type dscrType = typeof(int);
			int dscrOffset = 0;
			for (var fieldInfo in typeof(T).GetFields())
			{
				if (fieldInfo.Name == "$discriminator")
				{
					dscrOffset = fieldInfo.MemberOffset;
					dscrType = fieldInfo.FieldType;
				}
			}

			String outString = scope .(256);
			String fields = scope .(256);
			String fieldsDefine = scope .(64);
			String fieldsCheck = scope .(64);
			String type = scope .(32);
			outString.Append("switch (value)\n{\n");
			for (let enumcase in typeof(T).GetFields())
			{
				if (!enumcase.IsEnumCase) continue;
				outString.AppendF($"""
					case "{enumcase.Name}":

					""");
				bool noPayload = true;
				for (let field in enumcase.FieldType.GetFields())
				{
					noPayload = field.FieldType == typeof(void);
					if (!noPayload) break;
				}
				if (noPayload)
				{
					outString.AppendF($"""
							result = .{enumcase.Name};

						""");
					continue;
				}

				int i = 0;
				for (let tupField in enumcase.FieldType.GetFields())
				{
					type.Clear();
					// decltype({let a = default(TestFoo.Baz) case .Other(let p0); p0})
					type.AppendF($"decltype({{let a = default(T) case .{enumcase.Name}(");
					int ii = 0;
					for (;ii < @tupField.Index; ii++) type.Append("?, ");
					type.Append("let b, "); ii++;
					for (;ii < enumcase.FieldType.FieldCount; ii++) type.Append("?, ");
					type.RemoveFromEnd(2);
					type.Append("); b})");

					fieldsDefine.AppendF($"bool _{tupField.Name} = false;\n");
					fieldsCheck.AppendF($"Assert!(reader, _{tupField.Name}, \"{typeof(T)}.{enumcase.Name}.{tupField.Name} is missing\");\n");
					fields.AppendF($"""
						case .OpeningTag("{enumcase.Name}{i}"):
							Assert!(reader, !_{tupField.Name}, "duplicate {typeof(T)}.{enumcase.Name}.{tupField.Name}");
							_{tupField.Name} = true;
							(*({type}*)((uint8*)&result + {tupField.MemberOffset})) = Try!(DoDeserialize<{type}>(reader));
							next = Try!(reader.ParseNext());
							Assert!(reader, next case .OpeningEnd(true) || next case .ClosingTag("{enumcase.Name}{i}"), "Expected closing tag for {enumcase.Name}{i}");

					""");
					i++;
				}
				outString.AppendF($"""
					*({dscrType}*)((uint8*)&result + {dscrOffset}) = {enumcase.MemberOffset};
					Expect!(reader, XmlVisitable.OpeningEnd(false));

					{fieldsDefine}
					loop: while (true)
					{{
						next = Try!(reader.ParseNext());
						switch (next)
						{{
						case .ClosingTag:
							reader.Cycle(next);
							break loop;
					{fields}
						default:
							reader.Error($"Unexpected {{next}}");
							return .Err;
						}}
					}}
					{fieldsCheck}
				""");
				
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

	[Comptime(ConstEval=true)]
	static String NameOf<T>()
	{
		return typeof(T).GetName(..scope .());
	}

	public static Result<T> Deserialize<T>(XmlReader reader)
	{
		Try!(reader.ParseHeader());
		Assert!(reader, Try!(reader.ParseNext(true)) case .OpeningTag(NameOf<T>()), String.ConstF($"Expected element {NameOf<T>()}"));
		let result = Try!(DoDeserialize<T>(reader));
		Assert!(reader, Try!(reader.ParseNext()) case .ClosingTag(NameOf<T>()), String.ConstF($"Expected closing tag for {NameOf<T>()}"));
		return result;
	}
}

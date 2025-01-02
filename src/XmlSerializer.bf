using System;
using System.IO;
using System.Text;
using System.Reflection;
using System.Collections;
using System.Diagnostics;

namespace Xml;

/// won't serialize its target
[AttributeUsage(.Field)]
struct NoSerializeAttribute : Attribute;

/// will serialize its target even if it isn't public
[AttributeUsage(.Field)]
struct ForceSerializeAttribute : Attribute;

/// will serialize its target as an attribute instead of an element
[AttributeUsage(.Field)]
struct XmlAttributeSerializeAttribute : Attribute;

/// allows you to define custom serialization and deserialization code
interface IXmlSerializable
{
	// @todo docytpe and schema
	public static Result<void> Serialize(XmlBuilder outBuilder);
	public static Result<Self> Deserialize(XmlReader reader);
}

extension Xml
{
	public static Result<void> Serialize<T>(T input, XmlBuilder outBuilder)
	{
#unwarn
		String buffer = scope .(16);
		EmitSerilization<T>(.NoDoctype);
		return .Ok;
	}

	public static Result<void> SerializeInlineDoctype<T>(T input, XmlBuilder outBuilder)
	{
#unwarn
		String buffer = scope .(16);
		EmitSerilization<T>(.InlineDoctype);
		return .Ok;
	}

	public static Result<void> SerializeExternalDoctype<T>(T input, XmlBuilder outBuilder, MarkupUri doctypeUri)
	{
#unwarn
		String buffer = scope .(16);
		Try!(outBuilder.Write(XmlHeader(.V1_1, .UTF_8, false, null, typeof(T).[ConstEval]GetName(..scope .())), doctypeUri));
		EmitSerilization<T>(.CustomHeader);
		return .Ok;
	}

	[Comptime(ConstEval=true)]
	public static String GetSerializationDoctype<T>()
	{
		return EmitSerilization<T>(.DoctypeOnly);
	}

	[Comptime(ConstEval=true)]
	private static String EmitSerilization<T>(SerializeEmitMode mode)
	{
		if (typeof(T).IsGenericParam)
			return .Empty;

		let root = typeof(T).GetName(..scope .(8));
		Doctype doctype = scope .();
		let body = DoEmitSerialization(typeof(T), scope String("input"), root, true, ..scope .(256), doctype, scope .());

		String string = scope .(256);
		StringStream stream = scope .(string, .Reference);
		XmlBuilder outBuilder = scope .(scope .(stream, .UTF8, 256));

		switch (mode)
		{
		case .CustomHeader:
			Compiler.MixinRoot(body);
			return .Empty;
		case .InlineDoctype:
			outBuilder.Write(XmlHeader(.V1_1, .UTF_8, true, doctype, root));
		case .NoDoctype:
			outBuilder.Write(XmlHeader(.V1_1, .UTF_8, true, null, root));
		case .DoctypeOnly:
			outBuilder.Write(doctype);
			return string.ToString(..scope .());
		}

		Compiler.MixinRoot(scope $"""
			outBuilder.[Friend]Write!(\"\"\"
			{string}
			\"\"\");

			{body}
			""");
		return .Empty;
	}

	private enum SerializeEmitMode
	{
		InlineDoctype,
		NoDoctype,
		DoctypeOnly,
		CustomHeader,
	}

	[Comptime]
	private static void DoEmitSerialization(Type type, StringView depth, String key, bool doDoctype, String outString, Doctype doctype, BumpAllocator alloc)
	{
		if (type == typeof(void) && !doDoctype)
			return;

		
		String attributes = scope .();
		String children = scope .(128);

		List<Doctype.ElementContents> childrenDoctype = new:alloc .();
		doctype.elements[key] = .(.AllOf(childrenDoctype), new:alloc .());

		void Nullable(String str)
		{
			if (doctype.elements[key].contents != .PCData)
			{
				Doctype.ElementContents* copy = new:alloc .();
				*copy = doctype.elements[key].contents;
				doctype.elements[key].contents = .AllOf(new:alloc .(1) { .Optional(copy) });
			}
			str?.AppendF($"""
				if ({depth} == null)
				{{
					Try!(outBuilder.Write(.OpeningEnd(true)));
					break;
				}}

				""");
		}
		if (type.IsNullable) Nullable(attributes);

		if (type.IsSubtypeOf(typeof(IXmlSerializable)))
		{
			doctype.elements[key] = .(.Any, doctype.elements[key].attlists);
			children.AppendF($"Try!({depth}.Serialize(outBuilder));\n");
		}
		else if (type.IsSubtypeOf(typeof(String)))
		{
			doctype.elements[key].contents = .PCData; 
			children.AppendF($"Try!(outBuilder.Write(.CharacterData({depth})));\n");
		}
		else if (type.IsSubtypeOf(typeof(StringView)))
		{
			doctype.elements[key].contents = .PCData; 
			children.AppendF($"Try!(outBuilder.Write(.CharacterData(scope .({depth}))));\n");
		}
		else if (type.IsPrimitive)
		{
			doctype.elements[key].contents = .PCData; 
			children.AppendF($"""
				buffer.Clear();
				{depth}.ToString(buffer);
				Try!(outBuilder.Write(.CharacterData(buffer)));

				""");
		}
		else if (type == typeof(void)) {}
		else if (type.IsPointer)
		{
			if (type.UnderlyingType == typeof(void))
				Internal.FatalError("Cannot serialize void*");
			outString..AppendF($"""
				if ({depth} == null)
				{{
					Try!(outBuilder.Write(.OpeningTag("{key}")));
					Try!(outBuilder.Write(.OpeningEnd(true)));
				}}
				else
				""").Append(' ');
			DoEmitSerialization(type.UnderlyingType, scope $"(*({depth}))", key, doDoctype, outString, doctype, alloc);
			Nullable(null);
			return;
		}
		else if (type.IsEnum)
		{
			List<String> options = new:alloc .();
			doctype.elements[key].attlists.Add("value", .(.OneOf(options), .Required));
			outString.AppendF($"""
				Try!(outBuilder.Write(.OpeningTag("{key}")));
				switch ({depth})
				\{

				""");

			String puller = scope .(16);
			String writer = scope .(128);
			for (let field in type.GetFields())
			{
				if (!field.IsEnumCase) continue;
				options.Add(new:alloc .(field.Name));

				puller.Clear();
				writer.Clear();
				if (field.FieldType.FieldCount > 0) do
				{
					puller.Append('(');
					for (let par in field.FieldType.GetFields())
					{
						String name = new:alloc .(field.Name);
						name.Append(@par.Index);
						puller.AppendF($"let {name}, ");
						childrenDoctype.Add(.Child(name));
						DoEmitSerialization(par.FieldType, name, name, false, writer, doctype, alloc);
					}
					if (puller.Length == 1)
					{
						puller.Clear();
						writer.Clear();
						break;
					}
					puller.RemoveFromEnd(2);
					puller.Append(')');
				}

				if (!writer.IsEmpty)
					writer.AppendF($"Try!(outBuilder.Write(.ClosingTag(\"{key}\")));");

				outString.AppendF($"""
					case .{field.Name}{puller}:
						Try!(outBuilder.Write(.Attribute("value", "{field.Name}")));
						Try!(outBuilder.Write(.OpeningEnd({puller.IsEmpty ? ("true") : ("false")})));
					{writer}

					""");
			}

			for (var child in ref childrenDoctype)
			{
				if (child case .Child(let name))
				{
					Doctype.ElementContents* holder = new:alloc .();
					*holder = .Child(name);
					child = .Optional(holder);
				}
			}

			outString.Append("}\n");
			return;
		}
		else
		{
			for (let field in type.GetFields())
			{
				if (field.IsStatic || field.IsConst || field.HasCustomAttribute<NoSerializeAttribute>()
					|| (!field.IsPublic && !field.HasCustomAttribute<ForceSerializeAttribute>())) continue;

				/*if (blocked.Contains(field.FieldType))
					Internal.FatalError(scope $"{field.FieldType} causes a circular data reference");*/

				StringView accessor = scope $"{depth}.{field.IsPublic ? ("") : ("[Friend]")}{field.Name}";

				if (field.HasCustomAttribute<XmlAttributeSerializeAttribute>())
				{
					doctype.elements[key].attlists.Add(new:alloc .(field.Name), .(.CData, .Required));

					switch (field.FieldType)
					{
					case typeof(String):
						attributes.AppendF($"Try!(outBuilder.Write(.Attribute(\"{field.Name}\", {accessor})));\n");
						continue;
					case typeof(StringView):
						attributes.AppendF($"Try!(outBuilder.Write(.Attribute(\"{field.Name}\", scope .({accessor}))));\n");
						continue;
					}

					if (field.FieldType.IsPrimitive)
					{
						attributes.AppendF($"""
							buffer.Clear();
							{accessor}.ToString(buffer);
							Try!(outBuilder.Write(.Attribute("{field.Name}", buffer));

							""");
						continue;
					}

					Internal.FatalError(scope $"Type {field.FieldType} cannot be serialized as an attribute while serializing field {type}.{field.Name}");
				}

				childrenDoctype.Add(.Child(new:alloc .(field.Name)));
				DoEmitSerialization(field.FieldType, accessor, new:alloc .(field.Name), false, children, doctype, alloc);
			}
		}

		if (children.IsEmpty)
		{
			doctype.elements[key].contents = .Empty;
		}

		outString.AppendF($"""
			do {{
			Try!(outBuilder.Write(.OpeningTag("{key}")));
			{attributes}
			

			""");
		if (children.IsEmpty)
		{
			outString.AppendF($"""
				Try!(outBuilder.Write(.OpeningEnd(true)));
				}}
				\n
				""");
			return;
		}
		outString.AppendF($"""
			Try!(outBuilder.Write(.OpeningEnd(false)));

			{children}

			Try!(outBuilder.Write(.ClosingTag("{key}")));
			}}
			\n
			""");
	}
}
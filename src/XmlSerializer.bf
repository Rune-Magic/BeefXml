using System;
using System.IO;
using System.Text;
using System.Reflection;
using System.Collections;
using System.Diagnostics;

namespace Xml;

/// won't serialize its target
[AttributeUsage(.Field)]
struct XmlNoSerializeAttribute : Attribute;

/// will serialize its target even if it isn't public
[AttributeUsage(.Field)]
struct XmlForceSerializeAttribute : Attribute;

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
	public static Result<void> Serialize<T>(T input, XmlBuilder outBuilder) where T : struct
	{
#unwarn
		String buffer = scope .(16);
		EmitSerilization<T>(.NoDoctype);
		return .Ok;
	}

	public static Result<void> SerializeDoctype<T>(T input, XmlBuilder outBuilder) where T : struct
	{
#unwarn
		String buffer = scope .(16);
		EmitSerilization<T>(.InlineDoctype);
		return .Ok;
	}

	public static Result<void> SerializeExternalDoctype<T>(T input, XmlBuilder outBuilder, MarkupUri doctypeUri) where T : struct
	{
#unwarn
		String buffer = scope .(16);
		Try!(outBuilder.Write(XmlHeader(.V1_1, .UTF_8, false, null, typeof(T).[ConstEval]GetName(..scope .())), doctypeUri));
		EmitSerilization<T>(.CustomHeader);
		return .Ok;
	}

	public static Result<void> WriteSerializationDoctype<T>(T input, XmlBuilder outBuilder) where T : struct
	{
#unwarn
		String buffer = scope .(16);
		EmitSerilization<T>(.DoctypeOnly);
		return .Ok;
	}

	[Comptime]
	private static void EmitSerilization<T>(SerializeEmitMode mode)
	{
		if (typeof(T).IsGenericParam)
			return;

		let root = typeof(T).GetName(..scope .(8));
		Doctype doctype = scope .();
		let body = DoEmitSerialization(typeof(T), scope String("input"), root, true, ..scope .(256), doctype, scope .());

		String string = scope .(256);
		StringStream stream = scope .(string, .Reference);
		XmlBuilder outBuilder = scope .(scope .(stream, .UTF8, 256));

		switch (mode)
		{
		case .CustomHeader:
		case .InlineDoctype:
			outBuilder.Write(XmlHeader(.V1_1, .UTF_8, true, doctype, root));
		case .NoDoctype:
			outBuilder.Write(XmlHeader(.V1_1, .UTF_8, true, null, root));
		case .DoctypeOnly:
			outBuilder.Write(doctype);
		}

		Compiler.MixinRoot(scope $"""
			outBuilder.[Friend]Write!(\"\"\"
			{string}
			\"\"\");

			{body}
			""");
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
		if (!type.IsValueType)
			Internal.FatalError(scope $"Only value types can be serialized and deserialized");

		if (type == typeof(void) && !doDoctype)
			return;

		String attributes = scope .();
		String children = scope .(128);

		List<Doctype.ElementContents> childrenDoctype = new:alloc .();
		doctype.elements[key] = .(.AllOf(childrenDoctype), new:alloc .());

		if (type.IsSubtypeOf(typeof(IXmlSerializable)))
		{
			doctype.elements[key] = .(.Any, doctype.elements[key].attlists);
			children.AppendF($"Try!({depth}.Serialize(outBuilder));\n");
		}
		else if (type.IsSubtypeOf(typeof(String)))
		{
			childrenDoctype.Add(.CData);
			children.AppendF($"Try!(outBuilder.Write(.CharacterData({depth})));\n");
		}
		else if (type.IsSubtypeOf(typeof(StringView)))
		{
			childrenDoctype.Add(.CData);
			children.AppendF($"Try!(outBuilder.Write(.CharacterData(scope .({depth}))));\n");
		}
		else if (type.IsPrimitive)
		{
			childrenDoctype.Add(.CData);
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
			DoEmitSerialization(type.UnderlyingType, scope $"(*({depth}))", key, doDoctype, outString, doctype, alloc);
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
				if (field.IsStatic || field.IsConst || field.HasCustomAttribute<XmlNoSerializeAttribute>()
					|| (!field.IsPublic && !field.HasCustomAttribute<XmlForceSerializeAttribute>())) continue;

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
						return;
					case typeof(StringView):
						attributes.AppendF($"Try!(outBuilder.Write(.Attribute(\"{field.Name}\", scope .({accessor}))));\n");
						return;
					}

					if (field.FieldType.IsPrimitive)
					{
						attributes.AppendF($"""
							buffer.Clear();
							{accessor}.ToString(buffer);
							Try!(outBuilder.Write(.Attribute("{field.Name}", buffer));

							""");
						return;
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
			Try!(outBuilder.Write(.OpeningTag("{key}")));
			{attributes}
			

			""");
		if (children.IsEmpty)
		{
			outString.AppendF($"""
				Try!(outBuilder.Write(.OpeningEnd(true)));

				""");
			return;
		}
		outString.AppendF($"""
			Try!(outBuilder.Write(.OpeningEnd(false)));

			{children}

			Try!(outBuilder.Write(.ClosingTag("{key}")));
			\n
			""");
	}
}
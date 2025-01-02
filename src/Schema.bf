using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

using internal Xml;
using Regex;

namespace Xml;

class XmlSchema
{
	[Inline]
	protected static Result<void> Assert(bool condition, XmlVisitorPipeline pipeline, StringView errorMsg, params Object[] args)
	{
		if (!condition)
		{
			pipeline.Reader.Error(errorMsg, params args);
			return .Err;
		}
		return .Ok;
	}

	public abstract class SchemaType
	{
		public abstract StringView Name { get; }
		public abstract Result<void> Validate(XmlVisitable node, XmlVisitorPipeline pipeline);
	}

	public class AnyType : SchemaType
	{
		public override StringView Name => "anyType";
		public override Result<void> Validate(XmlVisitable node, XmlVisitorPipeline pipeline)
			=> .Ok;
	}

	/// a string type, can be used by attributes
	public abstract class SimpleType : SchemaType
	{
		public abstract Result<void> Validate(String data, XmlVisitorPipeline pipeline);
		public override Result<void> Validate(XmlVisitable node, XmlVisitorPipeline pipeline)
		{
			if (node case .CharacterData(let data))
				return Validate(data, pipeline);
			pipeline.Reader.Error("Expected character data");
			return .Err;
		}

		//public abstract Span<>

		public abstract IResultVisitor<SimpleType> CreateRestrictionParser(XmlVisitorPipeline pipeline);
	}

	public class AnySimpleType : SimpleType
	{
		public override StringView Name => "anySimpleType";
		public override Result<void> Validate(String data, XmlVisitorPipeline pipeline)
		{
			return default;
		}

		public override IResultVisitor<SimpleType> CreateRestrictionParser(XmlVisitorPipeline pipeline)
		{
			return default;
		}
	}

	public static StringType stringType = new .() ~ delete _;
	public class StringType : SimpleType
	{
		public List<StringView> enumeration = null;
		public Range length = .(-1, -1);
		public RegexTreeNode pattern = null;
		public WhiteSpaceMode whiteSpaceMode = .Default;

		public override StringView Name => "string";

		public enum WhiteSpaceMode
		{
			/// removes leading and trailing whitespace per line
			Default,
			/// removes nothing
			Preserve,
			/// replaces all whitespace with spaces
			Replace,
			/// replaces all whitespace with spaces,
			/// removes leading and trailing whitespace per line
			/// and collapse multiple space to one
			Collapse,
		}

		public override Result<void> Validate(String data, XmlVisitorPipeline pipeline)
		{
			return .Ok;
		}

		public override IResultVisitor<SimpleType> CreateRestrictionParser(XmlVisitorPipeline pipeline) => new:(pipeline.Reader.alloc) RestrictionParser();
		public class RestrictionParser : XmlVisitor, IResultVisitor<SimpleType>
		{
			public override XmlVisitor.Options Flags => .None;
			public SimpleType Result { get => mResult; set => mResult = value as StringType; }
			protected StringType mResult;

			public override void Init()
			{
				mResult = new:Alloc .();
			}

			public override Action Visit(ref XmlVisitable node)
			{
				//Try!(Assert(node.RemoveNamespace(passed.Namespace), Pipeline, $"Unrecognized node: {node}"));

				switch (node)
				{
				case .OpeningTag(let name):
					Try!(Assert(name == "enumeration" || name == "pattern" || name == "whiteSpace" || name == "length" || name == "minLength" || name == "maxLength",
						Pipeline, $"Unexpected constraint '{name}'"));
				case .Attribute(let key, let value):
					Try!(Assert(key == "value", Pipeline, $"Unexpected attribute '{key}' only 'value' is valid here"));
					switch (TagDepth.Back)
					{
					case "enumeration":
						if (mResult.enumeration == null)
							mResult.enumeration = new:Alloc .(4);
						mResult.enumeration.Add(value);
					case "pattern":
						Try!(Assert(mResult.pattern == null, Pipeline, "Duplicate pattern"));
						mResult.pattern = Regex.Parse(value, Alloc);
					case "whiteSpace":
						Try!(Assert(mResult.whiteSpaceMode == .Default, Pipeline, "Duplicate whitespace mode specifier"));
						switch (value..ToLower())
						{
						case "preserve": mResult.whiteSpaceMode = .Preserve;
						case "replace": mResult.whiteSpaceMode = .Replace;
						case "collapse": mResult.whiteSpaceMode = .Collapse;
						default:
							Pipeline.Reader.Error($"Invalid whitespace mode: '{value}'");
							return .Error;
						}
					case "length":
						Try!(Assert(mResult.length == .(-1, -1), Pipeline, "Length already specified"));
						int length = .Parse(value);
						mResult.length = .(length, length);
					case "minLength":
						Try!(Assert(mResult.length.Start == -1, Pipeline, "Minimum length already specified"));
						mResult.length.Start = .Parse(value);
					case "maxLength":
						Try!(Assert(mResult.length.End == -1, Pipeline, "Maximum length already specified"));
						mResult.length.End = .Parse(value);
					default:
						Runtime.NotImplemented();
					}
				default:
				}

				return .Continue;
			}
		}
	}

	public class DecimalType : SimpleType
	{
		public override StringView Name => "decimal";

		public override Result<void> Validate(String data, XmlVisitorPipeline pipeline)
		{
			return default;
		}

		public override IResultVisitor<SimpleType> CreateRestrictionParser(XmlVisitorPipeline pipeline)
		{
			return default;
		}
	}

	class ComplexType
	{

	}
}
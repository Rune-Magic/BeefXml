using System;
using System.IO;
using System.Collections;
using System.Diagnostics;
using internal Xml;

namespace Xml;

class XmlSchema
{
	public abstract class SchemaType
	{
		public abstract Result<void> Validate(XmlVisitable node, XmlVisitorPipeline pipeline);
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

		public abstract IResultVisitor<SimpleType> CreateRestrictionParser(XmlVisitorPipeline pipeline);
	}

	public static StringType stringType = new .() ~ delete _;
	public class StringType : SimpleType
	{
		public override Result<void> Validate(String data, XmlVisitorPipeline pipeline)
		{
			return .Ok;
		}

		public override IResultVisitor<SimpleType> CreateRestrictionParser(XmlVisitorPipeline pipeline) => new:(pipeline.Reader.alloc) RestrictionParser();
		public class RestrictionParser : XmlVisitor, IResultVisitor<SimpleType>
		{
			public override XmlVisitor.Options Flags => .None;
			public SimpleType Result { get; set; }

			public override Action Visit(ref XmlVisitable node)
			{
				
			}
		}
	}

	class ComplexType
	{

	}
}
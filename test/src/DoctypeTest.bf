using Xml;
using System;
using System.IO;
using System.Diagnostics;
using System.Collections;

namespace Xml.Test;

internal static
{
	[Test]
	static void TestDoctypeParsing()
	{
		const let input = """
			<!ELEMENT root (child)>
			<!ELEMENT child EMPTY>
			<!ATTLIST child is_alive (yes|no) "yes">
			<!ENTITY entity "an entity">
			""";

		StringStream stream = scope .(input, .Reference);
		MarkupSource source = scope .(scope .(stream), "input");
		Doctype doctype;
		switch (Doctype.Parse(source))
		{
		case .Err:
			Test.FatalError();
			return;
		case .Ok(let val):
			doctype = val;
			defer:: delete doctype;
		}

		Test.Assert(source.Ended);

		for (let element in doctype.elements)
			switch (element.key)
			{
			case "root":
				Test.Assert(element.value.contents case .Child("child"));
			case "child":
				Test.Assert(element.value.contents case .Empty);
				Test.Assert(element.value.attlists.TryGet("is_alive", ?, let value));
				Test.Assert(value.type case .OneOf(let list));
				Test.Assert(list.Count == 2);
				Test.Assert(list[0] == "yes");
				Test.Assert(list[1] == "no");
				Test.Assert(value.value case .Value("yes"));
			default:
				Test.FatalError();
			}

		Test.Assert(doctype.entities.TryGet("entity", ?, let value));
		Test.Assert(value.uri case .Raw("an entity"));
	}

	[Test]
	static void TestDoctypeValidation()
	{
		const let input = """
			<?xml version="1.1" encoding="UTF-8"?>
			<!DOCTYPE root [
				<!ELEMENT root (child, reference, #CDATA)>
				<!-- comment -->
				<!ELEMENT child EMPTY>
				<!ATTLIST child arg ID #IMPLIED>
				<!ATTLIST child beef_good (yes|no) #FIXED "yes">
				<!ATTLIST reference refed IDREF #REQUIRED>
				<!ELEMENT reference EMPTY>
				<!ENTITY entity "some data">
			]>
			<root>
				<reference refed="SomeId" />
				<child arg="SomeId" beef_good="yes" />
				Random CData &entity;
			</root>
			""";

		StringStream stream = scope .(input, .Reference);
		MarkupSource source = scope .(scope .(stream), "input");
		XmlVisitorPipeline pipeline = scope .(new DoctypeValidator(), new TestXmlBuilderVisitor());

		Test.Assert(pipeline.Run(scope .(source)) case .Ok);
		Test.Assert(pipeline.CurrentHeader.doctype != null);
	}

	class TestXmlBuilderVisitor : XmlVisitor
	{
		public override Options Flags => .None;

		bool first = true;
		XmlBuilder builder = new .(Console.Out) ~ delete _;
		public override Action Visit(ref XmlVisitable node)
		{
			if (first)
			{
				builder.Write(Pipeline.CurrentHeader);
				first = false;
			}

			builder.Write(node);
			return .Continue;
		}
	}
}
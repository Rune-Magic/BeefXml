using Xml;
using System;
using System.IO;
using System.Diagnostics;

namespace Xml.Test;

static
{
	[Test]
	static void TestXmlSource()
	{
		const let input = """
			  <  a  >
			</a>

			< ! --  -->
			""";

		StringStream stream = scope .(input, .Reference);
		MarkupSource src = scope .(scope .(stream), "input", bufferSize: 6);

		Test.Assert(src.Consume('<'));
		Test.Assert(src.Consume("a", ">"));
		Test.Assert(src.ConsumeWhitespace());
		Test.Assert(src.Consume("<", "/", "a", ">"));
		Test.Assert(src.Consume("<", "!", "--"));
		Test.Assert(src.Consume("--", ">"));
	}

	[Test]
	static void TestXmlReader()
	{
		const let input = """
			<!-- comment yay -->
			<root arg='something'>
				<!-- skipped cdata -->
				<child />

				&lt;first /&gt;
				<![CDATA[<second />]]>
				&#x1f52e;
			</root>
			""";

		XmlVisitable[?] expected = .(
			.OpeningTag("root"), .Attribute("arg", "something"), .OpeningEnd(false),
				.OpeningTag("child"), .OpeningEnd(true),
				.CharacterData("<first />\n<second />\n\u{1F52E}"),
			.ClosingTag("root"), .EOF
		);

		StringStream stream = scope .(input, .Reference);
		MarkupSource src = scope .(scope .(stream), "input");
		XmlReader xml = scope .(src);

		XmlVisitable v;
		int i = 0;
		repeat 
		{
			v = xml.ParseNext();
			Test.Assert(v case expected[i], scope $"{v} does not match {expected[i]}");
			i++;
		}
		while (!(v case .EOF));
	}

	class TestVisitor : XmlVisitor
	{
		public override Options Flags => .None;

		private int i = 0;
		private static XmlVisitable[?] expected = .(
			.OpeningTag("root"), .Attribute("arg", "Beef is cool"), .OpeningEnd(false),
				.OpeningTag("child"), .OpeningEnd(true),
				.OpeningTag("info"), .OpeningEnd(false), .CharacterData("BeefLang is awesome"), .ClosingTag("info"),
			.ClosingTag("root")
		);

		public override Action Visit(ref XmlVisitable node)
		{
			let assert = node case expected[i];
			Test.Assert(assert, scope $"{node} does not match {expected[i]}");
			i++;
			return assert ? .Continue : .Error;
		}
	}

	[Test]
	static void TestXmlVisitor()
	{
		const let input = """
			<root arg="Beef is cool">
				<child />
				<info>BeefLang is awesome</info>
				<!-- comment -->
			</root>
			""";

		StringStream stream = scope .(input, .Reference);
		MarkupSource src = scope .(scope .(stream), "input");
		XmlVisitorPipeline pipeline = scope .(new TestVisitor());

		pipeline.Run(scope .(src));
	}

	class TestInsertVisitor : XmlInsertVisitor
	{
		public override Options Flags => .SkipTags;

		public override Action Visit(ref XmlVisitable node)
		{
			if (node case .Attribute("insert", "here"))
			{
				InsertBeforeCurrent(.Attribute("inserted", "before"));
				InsertAfterCurrent(.Attribute("inserted", "after"));
			}
			return .Continue;
		}
	}

	class TestInsertVisitorAcceptor : XmlVisitor
	{
		public override Options Flags => .None;

		private int i = 0;
		private static XmlVisitable[?] expected = .(
			.OpeningTag("test"),
				.Attribute("inserted", "before"),
				.Attribute("insert", "here"),
				.Attribute("inserted", "after"),
			.OpeningEnd(true)
		);

		public override Action Visit(ref XmlVisitable node)
		{
			let assert = node case expected[i];
			Test.Assert(assert, scope $"{node} does not match {expected[i]}");
			i++;
			return assert ? .Continue : .Error;
		}
	}

	[Test]
	static void TestXmlInsertVisitor()
	{
		const let input = """
			<test insert="here" />
			""";

		StringStream stream = scope .(input, .Reference);
		MarkupSource src = scope .(scope .(stream), "input");
		XmlVisitorPipeline pipeline = scope .(
			new TestInsertVisitor(),
			new TestInsertVisitorAcceptor()
		);

		pipeline.Run(scope .(src));
	}

	[Test]
	static void TestXmlElement()
	{
		const let input = """
			<?xml version="1.0"?>
			<catalog>
				some text
			   <book id="bk101">
			      <author>Gambardella, Matthew</author>
			      <title>XML Developer's Guide</title>
			      <genre>Computer</genre>
			      <price>44.95</price>
			      <publish_date>2000-10-01</publish_date>
			      <description>An in-depth look at creating applications 
			      with XML.</description>
			   </book>
			</catalog>
			""";

		XmlElement.Builder builder = new .();
		StringStream stream = scope .(input, .Reference);
		MarkupSource src = scope .(scope .(stream), "input");

		XmlVisitorPipeline pipeline = scope .(builder);
		pipeline.Run(scope .(src));

		scope XmlBuilder(Console.Out)
			..Write(pipeline.CurrentHeader)
			..Write(builder.Result);
	}
}
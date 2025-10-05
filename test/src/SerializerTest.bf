using System;
using System.IO;
using System.Collections;
using System.Diagnostics;
using Xml;

namespace Xml.Test;

static
{
	struct TestFoo
	{
		public int anInt = 69;
		public char8 aChar = '*';
		public Bar someBar = .();
		public Baz aBaz = .Other(null);

		public struct Bar
		{
			[XmlAttributeSerialize]
			public String aString = "hi";
		}

		public enum Baz
		{
			case First, Second;
			case Other(int*);
		}
	}

	[Test]
	static void TestXmlSerialze()
	{
		TestFoo foo = .();
		{
			StreamWriter outStream = scope .()..Create("dump.xml");
			XmlBuilder builder = scope .(outStream);
			Xml.SerializeInlineDoctype(foo, builder);
		}
		StreamReader inStream = scope .()..Open("dump.xml");
		MarkupSource source = scope .(inStream, "dump.xml");
		XmlReader reader = scope .(source);
		Test.Assert(Xml.Deserialize<TestFoo>(reader) case .Ok(let val));
		Test.Assert(val case foo);
		Console.Out.WriteLine(Xml.GetSerializationDoctype<TestFoo>());
	}
}
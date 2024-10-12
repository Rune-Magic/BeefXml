using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Xml.Test;

static
{
	struct TestFoo
	{
		public int anInt = 69;
		public char8 aChar = '*';
		public Bar someBar = .();
		public Baz aBaz = .Other(42);

		public struct Bar
		{
			[XmlAttributeSerialize]
			public String aString = "hi";
		}

		public enum Baz
		{
			case First, Second;
			case Other(int);
		}
	}

	[Test]
	static void TestSerialze()
	{
		TestFoo foo = .();decltype({let a = decltype(foo.aBaz).Other(69) case .Other(let p0); p0}) a = 0;
		XmlBuilder builder = scope .(Console.Out);
		Xml.SerializeDoctype(foo, builder);
		StringStream stream = scope .();
		builder.[Friend]stream = scope .(stream, .UTF8, 64);
		Xml.Serialize(foo, builder);
		MarkupSource source = scope .(scope .(stream), "TestFoo");
		XmlReader reader = scope .(source);
		Test.Assert(Xml.Deserialize<TestFoo>(reader) case .Ok(let val));
		Test.Assert(val case foo);

	}
}
<?php
// Writes the shared AB-2785 address table: "<verdict>\t<address>", verdict 1 =
// accepted by the panel (FILTER_VALIDATE_EMAIL) and by the installer, the hub
// tool and get.adminbolt.com; 0 = refused by all of them. Lines starting "#"
// are comments. Addresses PHP accepts but we refuse on purpose are listed
// with verdict 0 and a "# php-accepts" comment line before them.
$both = [
 'jane@example.com','jane.doe+trial@example.co.uk','o\'neil@example.com','a!#%&*/=?^_{|}~-z@example.com',
 'a@example.c','a@example.c0m','a@ex-ample.co-m','a@xn--p1ai.xn--p1ai','jane@example.xn--p1ai','a@sub-1.example.museum',
 'a@b.c','UPPER@EXAMPLE.COM','a--b@ex--ample.com','a@e--x.com',
 str_repeat('a',64).'@example.com', str_repeat('a',65).'@example.com',
 'a@'.str_repeat('b',63).'.com', 'a@'.str_repeat('b',64).'.com',
 'a@'.implode('.', array_fill(0,3,str_repeat('b',63))).'.'.str_repeat('c',56).'.com',
 'a@'.implode('.', array_fill(0,3,str_repeat('b',63))).'.'.str_repeat('c',57).'.com',
 '.a@example.com','a.@example.com','a..b@example.com','a@-example.com','a@example-.com','a@.example.com','a@example..com','a@example.com.',
 'a@example','a@example.123','a@1.2','a@example.1com','a@example.-com','a@example.com-','a@exa_mple.com','a@ex ample.com',
 'a b@example.com','a"b@example.com','"a b"@example.com','a;b@example.com','a,b@example.com','a(b)@example.com','a@b@example.com','a\\b@example.com',
 '@example.com','a@',
];
$ours_stricter = ['a$b@example.com','a`b@example.com','"ab"@example.com','a@[127.0.0.1]','a@[IPv6:::1]'];
echo "# AB-2785: e-mail addresses the panel's trial request (PHP FILTER_VALIDATE_EMAIL),\n";
echo "# the installer's --email check and the AI hub's install_adminbolt must agree on.\n";
echo "# <1 accepted | 0 refused><TAB><address>. Generated with PHP ".PHP_VERSION.": php tests/email_cases.php > tests/email_cases.tsv\n";
echo "# in AdminBolt/Installer (bolt-ai-hub keeps a copy in testdata/); do not edit by hand.\n";
foreach ($both as $e) { printf("%d\t%s\n", filter_var($e, FILTER_VALIDATE_EMAIL) !== false ? 1 : 0, $e); }
echo "# php-accepts: valid for PHP, refused on purpose before the install (\$, backtick, quoted names, IP literals)\n";
foreach ($ours_stricter as $e) { if (filter_var($e, FILTER_VALIDATE_EMAIL) === false) { fwrite(STDERR, "not php-valid: $e\n"); exit(1);} printf("0\t%s\n", $e); }

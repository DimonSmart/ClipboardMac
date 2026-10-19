# Engineering Rules Index

Next ID: ENG-0004

| Rule | Applicability | Applies when | Summary |
| --- | --- | --- | --- |
| ENG-0001 | Always | Every implementation task | Build an independent native Swift and AppKit product for macOS 26+. |
| ENG-0002 | Always | Every implementation task | Preserve the App/UI, services, domain/contracts, and infrastructure dependency boundary. |
| ENG-0003 | Conditional | Persisting clipboard history or changing its storage | Use system SQLite directly with migrations, transactions, and parameterized queries. |

Simple table with caption:

.. table:: Demonstration of simple table syntax.

   ===== ==== ====== =======
   Right Left Center Default
   ===== ==== ====== =======
   12    12   12     12
   123   123  123    123
   1     1    1      1
   ===== ==== ====== =======

Simple table without caption:

===== ==== ====== =======
Right Left Center Default
===== ==== ====== =======
12    12   12     12
123   123  123    123
1     1    1      1
===== ==== ====== =======

Simple table indented two spaces:

.. table:: Demonstration of simple table syntax.

   ===== ==== ====== =======
   Right Left Center Default
   ===== ==== ====== =======
   12    12   12     12
   123   123  123    123
   1     1    1      1
   ===== ==== ====== =======

Multiline table with caption:

.. table:: Here’s the caption. It may span multiple lines.

   +-----------+----------+------------+---------------------------+
   | Centered  | Left     | Right      | Default aligned           |
   | Header    | Aligned  | Aligned    |                           |
   +:=========:+:=========+===========:+:==========================+
   | First     | row      | 12.0       | Example of a row that     |
   |           |          |            | spans multiple lines.     |
   +-----------+----------+------------+---------------------------+
   | Second    | row      | 5.0        | Here’s another one. Note  |
   |           |          |            | the blank line between    |
   |           |          |            | rows.                     |
   +-----------+----------+------------+---------------------------+

Multiline table without caption:

+-----------+----------+------------+---------------------------+
| Centered  | Left     | Right      | Default aligned           |
| Header    | Aligned  | Aligned    |                           |
+:=========:+:=========+===========:+:==========================+
| First     | row      | 12.0       | Example of a row that     |
|           |          |            | spans multiple lines.     |
+-----------+----------+------------+---------------------------+
| Second    | row      | 5.0        | Here’s another one. Note  |
|           |          |            | the blank line between    |
|           |          |            | rows.                     |
+-----------+----------+------------+---------------------------+

Table without column headers:

=== === === ===
12  12  12  12
123 123 123 123
1   1   1   1
=== === === ===

Multiline table without column headers:

+-----------+----------+------------+---------------------------+
| First     | row      | 12.0       | Example of a row that     |
|           |          |            | spans multiple lines.     |
+-----------+----------+------------+---------------------------+
| Second    | row      | 5.0        | Here’s another one. Note  |
|           |          |            | the blank line between    |
|           |          |            | rows.                     |
+-----------+----------+------------+---------------------------+

# Library Management System

## Project Overview

The Library Management System is a real-world database solution developed to manage all operational aspects of a modern library, including books, members, librarians, borrowing processes, reservations, and fine payments. This project was developed as part of the SQL & Full Stack training track at the Information Technology Institute (ITI) and aims to demonstrate advanced database design, SQL implementation, and automation through triggers.

---

## Features

### Book & Copy Management

* Store detailed book information (ISBN, Title, Category, Publisher, Language, Year, Price).
* Track multiple copies per book with serial numbers and real-time availability status.

### Member Management

* Maintain personal information (name, email, address, registration date, membership type).
* Support for multi-address and status tracking.

### Librarian Management

* Store librarian info (role, contact, work schedule).
* Log librarian involvement in all borrowing and payment transactions.

### Borrowing & Return Workflow

* Track borrow dates, due dates, actual return dates.
* Prevent borrowing when overdue books exist.

### Reservation System

* Members can reserve books that are currently borrowed.
* Automatically assign returned books to the next member in the reservation queue.

### Payment & Fines

* Calculate late return fines dynamically.
* Create payment records and track their status (Paid/Unpaid).

---

## ERD & Schema

* The system is built on a normalized relational schema.
* Proper usage of primary and foreign keys to ensure referential integrity.
* Clear entity relationships between:

  * Book → BookCopy → Borrow → Payment
  * Member → Borrow / Reserve / Payment
  * Librarian → Borrow / Payment

---

## Triggers Implemented

1. Prevent Borrowing with Overdue Books
   Disallows borrowing if member has active overdue items.

2. Mark Copy as Unavailable After Borrowing
   Automatically sets book copy as unavailable.

3. Mark Copy as Available After Return
   Automatically restores availability after return.

4. Auto-Fulfill Reservation
   Assigns returned copy to next member in queue.

5. Generate Payment on Late Return
   Creates fine based on days late.

6. Attach Serial Number to Borrow Record
   Enhances traceability by storing serial number in borrow.

---

## Key SQL Queries (Sample)

* Overdue Book Report

```sql
SELECT b.title, m.fullname, DATEDIFF(DAY, br.expectedreturndate, GETDATE()) AS days_overdue
FROM borrow br
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
JOIN member m ON br.member_id = m.id
WHERE br.actualreturndate IS NULL AND br.expectedreturndate < GETDATE();
```

* Reservation Queue by Book

```sql
SELECT m.fullname, r.reservationdate
FROM reserve r
JOIN member m ON r.member_id = m.id
WHERE r.book_id = 101
ORDER BY r.reservationdate;
```

* Member Borrowing History

```sql
SELECT m.fullname, b.title, br.borrowdate, br.expectedreturndate, br.actualreturndate
FROM borrow br
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
JOIN member m ON br.member_id = m.id
WHERE m.id = 1030;
```

---

## Installation & Usage

1. Database Restoration
   Restore the `library.bak` SQL Server backup file.

2. Run Schema Script
   Execute `Library0.0.sql` to create tables, triggers, and insert base data.

3. Test Queries
   Use SSMS (SQL Server Management Studio) to run and verify 30+ advanced SQL queries.

4. Modify & Expand
   Add new categories, book types, reports, or connect it to a front-end app.

---

## Team Members

* Mostafa Rasheedy – Business Logic, Optimization, Documentation , ERD & SQL Tuning
* Abdelrahman Ahmed – DB Design, Testing
* Mina Ashraf – Schema & Triggers
* Nada Saeed – ERD & SQL Tuning

---

## Acknowledgments

* Thanks to ITI for enabling this hands-on learning experience.


## Tags

\#SQLProject #DBMS #LibrarySystem #ERD #SQLServer #Triggers #Teamwork #ITI #DataDriven

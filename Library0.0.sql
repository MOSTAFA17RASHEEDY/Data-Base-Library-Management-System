-- ============================================
--                Triggers 
-- ============================================

-- TRIGGER #1: Prevent borrowing for members with overdue books
-- Purpose: Blocks new book borrowing if the member has any overdue books
CREATE or alter TRIGGER trg_prevent_overdue_borrow
ON borrow
INSTEAD OF INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN borrow b ON i.member_id = b.member_id
        WHERE b.actualreturndate IS NULL AND b.expectedreturndate < GETDATE()
    )
    BEGIN
        THROW 50002, 'Member has overdue books and cannot borrow more until they are returned.', 1;
    END
    ELSE
    BEGIN
        INSERT INTO borrow (member_id, copy_id, employee_id, borrowdate, expectedreturndate)
        SELECT member_id, copy_id, employee_id, borrowdate, expectedreturndate
        FROM inserted;
    END
END;
GO

-- TRIGGER #2: Mark book copy as unavailable after borrowing
-- Purpose: Updates the book copy status to unavailable (0) when it's borrowed
CREATE TRIGGER trg_mark_copy_unavailable
ON borrow
AFTER INSERT
AS
BEGIN
    UPDATE bookcopy
    SET availability = 0
    WHERE id IN (SELECT copy_id FROM inserted);
END;
GO

-- TRIGGER #3: Mark book copy as available after return
-- Purpose: Updates the book copy status to available (1) when it's returned
CREATE TRIGGER trg_mark_copy_available
ON borrow
AFTER UPDATE
AS
BEGIN
    UPDATE bookcopy
    SET availability = 1
    WHERE id IN (
        SELECT copy_id FROM inserted
        WHERE actualreturndate IS NOT NULL
    );
END;
GO

-- TRIGGER #4: Auto-fulfill reservation on book return
-- Purpose: Automatically assigns a returned book to the next member in the reservation queue
CREATE TRIGGER trg_fulfill_reservation
ON borrow
AFTER UPDATE
AS
BEGIN
    IF UPDATE(actualreturndate)
    BEGIN
        DECLARE @book_id int, @copy_id int, @member_id int, @employee_id INT;

        SELECT TOP 1
            @copy_id = i.copy_id,
            @book_id = bc.book_id
        FROM inserted i
        JOIN bookcopy bc ON i.copy_id = bc.id
        WHERE i.actualreturndate IS NOT NULL;

        SELECT TOP 1 @member_id = member_id
        FROM reserve
        WHERE book_id = @book_id
        ORDER BY reservationdate;

        SELECT TOP 1 @employee_id = id FROM librarian;

        IF @member_id IS NOT NULL AND @employee_id IS NOT NULL
        BEGIN
            INSERT INTO borrow (member_id, copy_id, employee_id, borrowdate, expectedreturndate)
            VALUES (@member_id, @copy_id, @employee_id, GETDATE(), DATEADD(DAY, 14, GETDATE()));

            DELETE FROM reserve
            WHERE member_id = @member_id AND book_id = @book_id;
        END;
    END;
END;
GO

-- TRIGGER #5: Create payment record with fine for late return
-- Purpose: Generates a payment record with fine calculation when a book is returned late
CREATE TRIGGER trg_create_payment_on_late_return
ON borrow
AFTER UPDATE
AS
BEGIN
    IF EXISTS (
        SELECT 1 FROM inserted i
        WHERE i.actualreturndate IS NOT NULL AND i.actualreturndate > i.expectedreturndate
    )
    BEGIN
        INSERT INTO Payment (BorrowingID, EmployeeID, amount, FineAmount, TotalAmount, Note, Status)
        SELECT 
            i.id,
            i.employee_id,
            DATEDIFF(DAY, i.borrowdate, i.actualreturndate) * b.PricePerDay,
            DATEDIFF(DAY, i.expectedreturndate, i.actualreturndate) * 5.00,
            (DATEDIFF(DAY, i.borrowdate, i.actualreturndate) * b.PricePerDay) + 
            (DATEDIFF(DAY, i.expectedreturndate, i.actualreturndate) * 5.00),
            'Late return',
            0
        FROM inserted i
        JOIN borrow br ON i.id = br.id
        JOIN bookcopy bc ON br.copy_id = bc.id
        JOIN book b ON bc.book_id = b.id
        WHERE i.actualreturndate > i.expectedreturndate
          AND NOT EXISTS (
              SELECT 1 FROM Payment p WHERE p.BorrowingID = i.id
          );
    END;
END;
GO

-- TRIGGER #6: Add serial number to borrow record
-- Purpose: Copies the book's serial number to the borrow record for reference
CREATE TRIGGER trg_set_borrow_serialnumber
ON borrow
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE b
    SET b.serialnumber = bc.serialnumber
    FROM borrow b
    JOIN inserted i ON b.id = i.id
    JOIN bookcopy bc ON i.copy_id = bc.id;
END;
GO

-- ============================================
--                SQL QUERIES
-- ============================================

-- QUERY #1: List all books currently due for return in the next 7 days
-- Purpose: Enables proactive reminders to members about upcoming returns
SELECT m.fullname AS member_name, m.email, b.title, br.borrowdate, 
       br.expectedreturndate, DATEDIFF(DAY, GETDATE(), br.expectedreturndate) AS days_remaining
FROM book b
JOIN bookcopy bc ON b.id = bc.book_id
JOIN borrow br ON bc.id = br.copy_id
JOIN member m ON br.member_id = m.id
WHERE br.actualreturndate IS NULL 
AND br.expectedreturndate BETWEEN GETDATE() AND DATEADD(DAY, 7, GETDATE())
ORDER BY br.expectedreturndate;

-- QUERY #2: List overdue books with days overdue and potential fine amount
-- Purpose: Provides actionable information for contacting members about overdue books
SELECT b.title, m.fullname AS member_name, m.email, 
       br.expectedreturndate, 
       DATEDIFF(DAY, br.expectedreturndate, GETDATE()) AS days_overdue,
       DATEDIFF(DAY, br.expectedreturndate, GETDATE()) * 5.00 AS estimated_fine,
       CASE 
           WHEN EXISTS (SELECT 1 FROM Payment p WHERE p.BorrowingID = br.id) THEN 'Yes'
           ELSE 'No'
       END AS payment_created
FROM book b
JOIN bookcopy bc ON b.id = bc.book_id
JOIN borrow br ON bc.id = br.copy_id
JOIN member m ON br.member_id = m.id
WHERE br.actualreturndate IS NULL AND br.expectedreturndate < GETDATE()
ORDER BY days_overdue DESC;

-- QUERY #3: Show reservation queue for a specific book
-- Purpose: Displays the waiting list for a book by reservation date
SELECT m.fullname, r.*
FROM reserve r
JOIN member m ON r.member_id = m.id
WHERE r.book_id = 105
ORDER BY r.reservationdate;

-- QUERY #4: Get all borrowing transactions handled by a specific librarian
-- Purpose: Lists all book borrowings processed by a particular librarian
SELECT br.id AS borrow_id, m.fullname AS member_name, b.title, br.borrowdate   
FROM borrow br
JOIN member m ON br.member_id = m.id
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
WHERE br.employee_id = 2005;

-- QUERY #5: List members with unpaid payments and their contact information
-- Purpose: Facilitates collection of unpaid fees with complete contact details
SELECT m.id, m.fullname, m.email, a.street, a.city, a.postalcode,
       COUNT(p.PaymentID) AS unpaid_count,
       SUM(p.TotalAmount) AS total_unpaid
FROM member m
JOIN address a ON m.address_id = a.id
JOIN borrow br ON m.id = br.member_id
JOIN Payment p ON br.id = p.BorrowingID
WHERE p.Status = 0
GROUP BY m.id, m.fullname, m.email, a.street, a.city, a.postalcode
HAVING SUM(p.TotalAmount) > 0
ORDER BY total_unpaid DESC;

-- QUERY #6: Find all available book copies of a specific book
-- Purpose: Shows which copies of a particular book are available for borrowing
SELECT b.id, b.title, bc.serialnumber, bc.availability
FROM bookcopy bc
JOIN book b ON bc.book_id = b.id
WHERE b.title = 'Tareekh Misr' AND bc.availability = 1;

-- QUERY #7: Count the number of books borrowed per member
-- Purpose: Provides statistics on borrowing activity by member
SELECT m.fullname, COUNT(br.id) AS books_borrowed
FROM member m
JOIN borrow br ON m.id = br.member_id
GROUP BY m.fullname
ORDER BY COUNT(br.id) DESC;

-- QUERY #8: List books not borrowed in the past 6 months
-- Purpose: Identifies potentially unpopular books for collection management
SELECT b.*
FROM book b
WHERE b.id NOT IN (
  SELECT bc.book_id
  FROM bookcopy bc
  JOIN borrow br ON bc.id = br.copy_id
  WHERE br.borrowdate >= DATEADD(MONTH, -6, GETDATE())
);

-- QUERY #9: Show the most borrowed books
-- Purpose: Identifies the most popular books for acquisition planning
SELECT b.title, COUNT(*) AS borrow_count
FROM borrow br
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
GROUP BY b.title
ORDER BY borrow_count DESC;

-- QUERY #10: Get all members who registered this year
-- Purpose: Lists new library members for the current year
SELECT *
FROM member
WHERE YEAR(dateofregistration) = YEAR(GETDATE());

-- QUERY #11: Find books that are currently reserved
-- Purpose: Shows books with active reservation requests
SELECT DISTINCT b.title
FROM reserve r
JOIN book b ON r.book_id = b.id;

-- QUERY #12: List librarians who processed the most borrowings
-- Purpose: Identifies the most active librarians for workload assessment
SELECT l.fullname, COUNT(*) AS borrowings_handled
FROM borrow br
JOIN librarian l ON br.employee_id = l.id
GROUP BY l.fullname
ORDER BY borrowings_handled DESC;

-- QUERY #13: Get details of books returned late
-- Purpose: Reports on late returns for fine assessment and pattern analysis
SELECT b.title, br.actualreturndate, br.expectedreturndate, DATEDIFF(DAY, br.expectedreturndate, br.actualreturndate) AS days_late
FROM borrow br
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
WHERE br.actualreturndate > br.expectedreturndate;

-- QUERY #14: Find members who never borrowed a book
-- Purpose: Identifies inactive members for engagement campaigns
SELECT m.*
FROM member m
LEFT JOIN borrow br ON m.id = br.member_id
WHERE br.id IS NULL;

-- QUERY #15: Display all books along with their current availability status
-- Purpose: Shows the availability status of each book copy in the library
SELECT b.title, bc.serialnumber, bc.availability
FROM book b
JOIN bookcopy bc ON b.id = bc.book_id;

-- QUERY #16: Retrieve Member Details by Name
-- Purpose: Fetches complete member information including address by name
SELECT m.id, m.fullname, m.email, a.street, a.city
FROM member m
JOIN address a ON m.address_id = a.id
WHERE m.fullname = 'Mostafa Ali';

-- QUERY #17: Check Book Availability by Title
-- Purpose: Shows the availability status of all copies of a specific book
SELECT b.title, bc.serialnumber, bc.availability
FROM book b
JOIN bookcopy bc ON b.id = bc.book_id
WHERE b.title = 'Tareekh Misr';

-- QUERY #18: Retrieve Borrowing History by Member
-- Purpose: Displays the complete borrowing history for a specific member
SELECT m.fullname, b.title, bc.serialnumber, br.borrowdate, br.expectedreturndate, br.actualreturndate
FROM member m
JOIN borrow br ON m.id = br.member_id
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
WHERE m.id = 1027;

-- QUERY #19: Member account summary with borrowing history and payment status
-- Purpose: Provides a complete overview of a member's account for customer service
SELECT 
    m.fullname, 
    m.email,
    m.membershiptype,
    m.dateofregistration,
    CASE m.status WHEN 1 THEN 'Active' ELSE 'Inactive' END AS member_status,
    (SELECT COUNT(*) FROM borrow WHERE member_id = m.id) AS total_borrows,
    (SELECT COUNT(*) FROM borrow WHERE member_id = m.id AND actualreturndate IS NULL) AS current_borrows,
    (SELECT COUNT(*) FROM Payment p JOIN borrow b ON p.BorrowingID = b.id WHERE b.member_id = m.id AND p.Status = 0) AS unpaid_payments,
    (SELECT SUM(TotalAmount) FROM Payment p JOIN borrow b ON p.BorrowingID = b.id WHERE b.member_id = m.id AND p.Status = 0) AS outstanding_balance
FROM member m
WHERE m.id = 1030;

-- QUERY #20: Show Reservations by Book Title
-- Purpose: Lists all reservations for a specific book title
SELECT b.title, m.fullname, r.reservationdate
FROM book b
JOIN reserve r ON b.id = r.book_id
JOIN member m ON r.member_id = m.id
WHERE b.title = 'Learning Python';

-- QUERY #21: Retrieve Librarian Details by Role
-- Purpose: Fetches librarian information filtered by their assigned role
SELECT id, fullname, email, phonenumber, workschedule
FROM librarian
WHERE role = 'Senior Librarian';



-- QUERY #23: Find categories with no books assigned
-- Purpose: Identifies empty categories that may need attention
SELECT c.id, c.name
FROM category c
LEFT JOIN book b ON c.id = b.category_id
WHERE b.id IS NULL;

-- QUERY #24: List books in a specific category
-- Purpose: Shows all books in a particular category for browsing
SELECT c.name AS category_name, b.title
FROM category c
JOIN book b ON c.id = b.category_id
WHERE c.name = 'Comedy'
ORDER BY b.title;

-- QUERY #25: Count the total number of categories
-- Purpose: Gets a simple count of all book categories in the system
SELECT COUNT(*) AS total_categories
FROM category;

-- QUERY #26: List categories and their available book copies
-- Purpose: Shows how many available copies exist in each category
SELECT c.name AS category_name, COUNT(bc.id) AS available_copies
FROM category c
LEFT JOIN book b ON c.id = b.category_id
LEFT JOIN bookcopy bc ON b.id = bc.book_id
WHERE bc.availability = 1 OR bc.id IS NULL
GROUP BY c.name
ORDER BY available_copies DESC;

-- QUERY #27: Find most popular categories by borrowings
-- Purpose: Identifies which book categories are most frequently borrowed
SELECT c.name AS category_name, COUNT(br.id) AS borrow_count
FROM category c
JOIN book b ON c.id = b.category_id
JOIN bookcopy bc ON b.id = bc.book_id
LEFT JOIN borrow br ON bc.id = br.copy_id
GROUP BY c.name
ORDER BY borrow_count DESC;

-- QUERY #28: List all unpaid fines
-- Purpose: Shows all outstanding payments that need to be collected
SELECT p.PaymentID, m.fullname AS member_name, b.title AS book_title, 
       p.amount, p.FineAmount, p.TotalAmount, p.Note
FROM Payment p
JOIN borrow br ON p.BorrowingID = br.id
JOIN member m ON br.member_id = m.id
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
WHERE p.Status = 0
ORDER BY p.TotalAmount DESC;

-- QUERY #29: Calculate total revenue from borrowing fees
-- Purpose: Shows total income generated from basic borrowing fees (excluding fines)
SELECT SUM(amount) AS total_borrowing_revenue
FROM Payment
WHERE Status = 1;

-- QUERY #30: Calculate total revenue from late fees
-- Purpose: Shows total income generated specifically from late return fines
SELECT SUM(FineAmount) AS total_fine_revenue
FROM Payment
WHERE Status = 1;

-- QUERY #31: Find members with highest total payments
-- Purpose: Identifies the library's most valuable patrons in terms of revenue
SELECT m.id, m.fullname, m.email, SUM(p.TotalAmount) AS total_paid
FROM Payment p
JOIN borrow br ON p.BorrowingID = br.id
JOIN member m ON br.member_id = m.id
WHERE p.Status = 1
GROUP BY m.id, m.fullname, m.email
ORDER BY total_paid DESC;

-- QUERY #32: Get payment history for a specific member
-- Purpose: Shows complete payment history for a specific library member
SELECT p.PaymentID, b.title AS book_title, p.amount AS borrowing_fee, 
       p.FineAmount, p.TotalAmount, p.Note, 
       CASE WHEN p.Status = 1 THEN 'Paid' ELSE 'Unpaid' END AS payment_status,
       br.borrowdate, br.actualreturndate
FROM Payment p
JOIN borrow br ON p.BorrowingID = br.id
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
WHERE br.member_id = 1030
ORDER BY br.borrowdate DESC;

-- QUERY #33: Calculate monthly revenue report
-- Purpose: Shows payment totals grouped by month for financial reporting
SELECT 
    YEAR(br.actualreturndate) AS year,
    MONTH(br.actualreturndate) AS month,
    COUNT(p.PaymentID) AS payment_count,
    SUM(p.amount) AS borrowing_revenue,
    SUM(p.FineAmount) AS fine_revenue,
    SUM(p.TotalAmount) AS total_revenue
FROM Payment p
JOIN borrow br ON p.BorrowingID = br.id
WHERE p.Status = 1
GROUP BY YEAR(br.actualreturndate), MONTH(br.actualreturndate)
ORDER BY year DESC, month DESC;

-- QUERY #34: Find payments with high fine amounts 
-- Purpose: Identifies payments with unusually high fine amounts for review
SELECT p.PaymentID, m.fullname AS member_name, b.title AS book_title,
       p.FineAmount, br.expectedreturndate, br.actualreturndate,
       DATEDIFF(DAY, br.expectedreturndate, br.actualreturndate) AS days_late
FROM Payment p
JOIN borrow br ON p.BorrowingID = br.id
JOIN member m ON br.member_id = m.id
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
WHERE p.FineAmount > 10.00
ORDER BY p.FineAmount DESC;

-- QUERY #35: Find payments processed by a specific librarian
-- Purpose: Shows all payments handled by a specific library employee
SELECT p.PaymentID, m.fullname AS member_name, b.title AS book_title,
       p.TotalAmount, l.fullname AS processed_by, p.Note
FROM Payment p
JOIN borrow br ON p.BorrowingID = br.id
JOIN librarian l ON p.EmployeeID = l.id
JOIN member m ON br.member_id = m.id
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
WHERE l.id = 2005
ORDER BY p.PaymentID;

-- QUERY #36: Average fine amount per book category
-- Purpose: Shows which book categories generate the highest fine amounts
SELECT b.category, AVG(p.FineAmount) AS avg_fine_amount,
       COUNT(p.PaymentID) AS payment_count
FROM Payment p
JOIN borrow br ON p.BorrowingID = br.id
JOIN bookcopy bc ON br.copy_id = bc.id
JOIN book b ON bc.book_id = b.id
WHERE p.FineAmount > 0
GROUP BY b.category
ORDER BY avg_fine_amount DESC;

-- QUERY #37: Summary of payment status
-- Purpose: Provides a quick overview of paid vs unpaid payments
SELECT 
    CASE WHEN Status = 1 THEN 'Paid' ELSE 'Unpaid' END AS payment_status,
    COUNT(*) AS payment_count,
    SUM(TotalAmount) AS total_amount
FROM Payment
GROUP BY Status;


-- ============================================
--           QUERIES TO TEST TRIGGERS
-- ============================================

-- TEST #1: Attempt to borrow again with the same member (should throw error)
-- Purpose: Tests the trigger that prevents borrowing for members with overdue books
INSERT INTO borrow (member_id, copy_id, employee_id, borrowdate, expectedreturndate)
VALUES (1032, 77, 2012, GETDATE(), DATEADD(DAY, 14, GETDATE()));

-- TEST #2: Test book availability update on return
-- Purpose: Tests the trigger that updates book availability when returned
SELECT * FROM bookcopy WHERE id = 11; -- 0 unavailabil
UPDATE borrow 
SET actualreturndate = GETDATE()
WHERE copy_id = 11;
SELECT * FROM bookcopy WHERE id = 11; -- must be 1 availabil

-- TEST #3: Test reservation fulfillment process
-- Purpose: Tests the trigger that auto-assigns returned books to reserved members
-- Step 1: Create a reservation for member 1037 for a book
INSERT INTO reserve (id, book_id, member_id, reservationdate)
VALUES (15, 117, 1037, GETDATE());

-- Step 2: Simulate returning a book of that type
UPDATE borrow
SET actualreturndate = GETDATE()
WHERE copy_id IN (
    SELECT id FROM bookcopy WHERE book_id = 117
);

-- Check if new borrow was made for member 1037
SELECT * FROM borrow WHERE member_id = 1037 ORDER BY borrowdate DESC;

-- TEST #4: Test payment creation for late return
-- Purpose: Tests the trigger that creates payment records for late returns
UPDATE borrow
SET actualreturndate = '2025-04-10'
WHERE member_id = 1030 AND copy_id = 10;

SELECT * FROM Payment WHERE BorrowingID IN (
    SELECT id FROM borrow WHERE member_id = 1030 AND copy_id = 10
);
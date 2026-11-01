-- =====================================================================
--  LIBRARY MANAGEMENT SYSTEM  |  FILE 03: Views, Functions, Procedures, Triggers
--  Run AFTER 02_data.sql.  (Triggers are created last on purpose, so the
--  sample data loads without them firing.)
-- =====================================================================
USE library_db;

-- =====================================================================
--  PART A: VIEWS  (Unit 2: views / data abstraction, external level of the
--  three-schema architecture. The app reads these instead of raw tables.)
-- =====================================================================

CREATE OR REPLACE VIEW v_book_catalog AS
SELECT b.book_id, b.isbn, b.title, b.publication_year, b.edition, b.pages, b.price, b.ebook_url,
       p.name AS publisher, l.name AS language,
       (SELECT GROUP_CONCAT(a.full_name ORDER BY ba.author_order SEPARATOR ', ')
          FROM book_authors ba JOIN authors a ON a.author_id = ba.author_id
         WHERE ba.book_id = b.book_id) AS authors,
       (SELECT GROUP_CONCAT(c.name ORDER BY c.name SEPARATOR ', ')
          FROM book_categories bc JOIN categories c ON c.category_id = bc.category_id
         WHERE bc.book_id = b.book_id) AS categories,
       (SELECT COUNT(*) FROM book_copies x WHERE x.book_id = b.book_id AND x.status <> 'Lost') AS total_copies,
       (SELECT COUNT(*) FROM book_copies x WHERE x.book_id = b.book_id AND x.status = 'Available') AS available_copies,
       (SELECT ROUND(AVG(r.rating), 1) FROM reviews r WHERE r.book_id = b.book_id) AS avg_rating,
       (SELECT COUNT(*) FROM reviews r WHERE r.book_id = b.book_id) AS review_count
FROM books b
JOIN publishers p ON p.publisher_id = b.publisher_id
JOIN languages  l ON l.language_id  = b.language_id;

CREATE OR REPLACE VIEW v_active_loans AS
SELECT i.issue_id, i.member_id, m.full_name AS member_name, bk.book_id, bk.title,
       c.barcode, br.branch_name, i.issue_date, i.due_date, i.renew_count,
       GREATEST(DATEDIFF(CURRENT_DATE, i.due_date), 0) AS days_overdue,
       GREATEST(DATEDIFF(CURRENT_DATE, i.due_date), 0) * mp.fine_per_day AS fine_so_far
FROM issues i
JOIN members m ON m.member_id = i.member_id
JOIN membership_plans mp ON mp.plan_id = m.plan_id
JOIN book_copies c ON c.copy_id = i.copy_id
JOIN books bk ON bk.book_id = c.book_id
JOIN shelves s ON s.shelf_id = c.shelf_id
JOIN branches br ON br.branch_id = s.branch_id
WHERE i.status = 'Issued';

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT * FROM v_active_loans WHERE days_overdue > 0;

CREATE OR REPLACE VIEW v_member_summary AS
SELECT m.member_id, m.full_name, m.email, m.status, mp.plan_name, mp.max_books, m.expiry_date,
       (SELECT COUNT(*) FROM issues i WHERE i.member_id = m.member_id AND i.status = 'Issued') AS open_loans,
       (SELECT COUNT(*) FROM issues i WHERE i.member_id = m.member_id) AS total_loans,
       IFNULL((SELECT SUM(f.amount) FROM fines f JOIN issues i ON i.issue_id = f.issue_id
                WHERE i.member_id = m.member_id AND f.status = 'Unpaid'), 0) AS unpaid_fines
FROM members m JOIN membership_plans mp ON mp.plan_id = m.plan_id;

CREATE OR REPLACE VIEW v_fine_details AS
SELECT f.fine_id, f.issue_id, i.member_id, m.full_name AS member_name, bk.title,
       f.amount, IFNULL(pay.paid, 0) AS paid, f.amount - IFNULL(pay.paid, 0) AS outstanding,
       f.reason, f.status, f.assessed_on
FROM fines f
JOIN issues i ON i.issue_id = f.issue_id
JOIN members m ON m.member_id = i.member_id
JOIN book_copies c ON c.copy_id = i.copy_id
JOIN books bk ON bk.book_id = c.book_id
LEFT JOIN (SELECT fine_id, SUM(amount) AS paid FROM payments GROUP BY fine_id) pay ON pay.fine_id = f.fine_id;

CREATE OR REPLACE VIEW v_popular_books AS
SELECT bk.book_id, bk.title, COUNT(i.issue_id) AS total_loans,
       COUNT(DISTINCT i.member_id) AS unique_readers
FROM books bk
JOIN book_copies c ON c.book_id = bk.book_id
JOIN issues i ON i.copy_id = c.copy_id
GROUP BY bk.book_id, bk.title;

-- Data mining (Unit 5): market-basket style "readers who borrowed A also borrowed B"
CREATE OR REPLACE VIEW v_member_books AS
SELECT DISTINCT i.member_id, c.book_id
FROM issues i JOIN book_copies c ON c.copy_id = i.copy_id;

CREATE OR REPLACE VIEW v_also_borrowed AS
SELECT a.book_id, b.book_id AS also_book_id, COUNT(*) AS common_readers
FROM v_member_books a
JOIN v_member_books b ON a.member_id = b.member_id AND a.book_id <> b.book_id
GROUP BY a.book_id, b.book_id;

CREATE OR REPLACE VIEW v_branch_inventory AS
SELECT br.branch_id, br.branch_name,
       COUNT(c.copy_id) AS total_copies,
       SUM(c.status = 'Available') AS available,
       SUM(c.status = 'Issued') AS issued,
       SUM(c.status IN ('Lost','Damaged')) AS lost_or_damaged
FROM branches br
LEFT JOIN shelves s ON s.branch_id = br.branch_id
LEFT JOIN book_copies c ON c.shelf_id = s.shelf_id
GROUP BY br.branch_id, br.branch_name;

-- =====================================================================
--  PART B: FUNCTIONS, PROCEDURES, TRIGGERS
-- =====================================================================
DELIMITER $$

-- ---------------------------------------------------------------------
-- FUNCTIONS
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_calc_fine$$
CREATE FUNCTION fn_calc_fine(p_issue_id INT UNSIGNED) RETURNS DECIMAL(8,2)
READS SQL DATA
BEGIN
    DECLARE v_days INT DEFAULT 0;
    DECLARE v_rate DECIMAL(6,2) DEFAULT 0;
    SELECT GREATEST(DATEDIFF(COALESCE(i.return_date, CURRENT_DATE), i.due_date), 0), mp.fine_per_day
      INTO v_days, v_rate
      FROM issues i
      JOIN members m ON m.member_id = i.member_id
      JOIN membership_plans mp ON mp.plan_id = m.plan_id
     WHERE i.issue_id = p_issue_id;
    RETURN IFNULL(v_days * v_rate, 0);
END$$

DROP FUNCTION IF EXISTS fn_member_outstanding$$
CREATE FUNCTION fn_member_outstanding(p_member_id INT UNSIGNED) RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_total DECIMAL(10,2);
    SELECT IFNULL(SUM(d.outstanding), 0) INTO v_total
      FROM v_fine_details d
     WHERE d.member_id = p_member_id AND d.status = 'Unpaid';
    RETURN v_total;
END$$

DROP FUNCTION IF EXISTS fn_available_copies$$
CREATE FUNCTION fn_available_copies(p_book_id INT UNSIGNED) RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_n INT;
    SELECT COUNT(*) INTO v_n FROM book_copies WHERE book_id = p_book_id AND status = 'Available';
    RETURN v_n;
END$$

-- ---------------------------------------------------------------------
-- PROCEDURES  (each is one ACID transaction; Unit 5)
-- ---------------------------------------------------------------------

-- ISSUE A BOOK: locks the copy row and the member row (SELECT ... FOR UPDATE),
-- so two librarians cannot issue the last copy at the same moment.
DROP PROCEDURE IF EXISTS sp_issue_book$$
CREATE PROCEDURE sp_issue_book(IN p_member_id INT UNSIGNED, IN p_copy_id INT UNSIGNED, IN p_staff_id INT UNSIGNED)
BEGIN
    DECLARE v_copy_status VARCHAR(20);
    DECLARE v_book INT UNSIGNED;
    DECLARE v_mstatus VARCHAR(20);
    DECLARE v_expiry DATE;
    DECLARE v_max INT;
    DECLARE v_days INT;
    DECLARE v_open INT DEFAULT 0;
    DECLARE v_overdue INT DEFAULT 0;
    DECLARE v_res INT UNSIGNED;
    DECLARE v_issue INT UNSIGNED;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT status, book_id INTO v_copy_status, v_book
      FROM book_copies WHERE copy_id = p_copy_id FOR UPDATE;
    IF v_copy_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Copy not found';
    END IF;

    SELECT m.status, m.expiry_date, mp.max_books, mp.loan_days
      INTO v_mstatus, v_expiry, v_max, v_days
      FROM members m JOIN membership_plans mp ON mp.plan_id = m.plan_id
     WHERE m.member_id = p_member_id FOR UPDATE;
    IF v_mstatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member not found';
    END IF;

    IF v_mstatus <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member account is not active';
    END IF;
    IF v_expiry < CURRENT_DATE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Membership has expired';
    END IF;

    SELECT COUNT(*), IFNULL(SUM(due_date < CURRENT_DATE), 0) INTO v_open, v_overdue
      FROM issues WHERE member_id = p_member_id AND status = 'Issued';
    IF v_open >= v_max THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borrowing limit of the membership plan reached';
    END IF;
    IF v_overdue > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Member has overdue books; return them first';
    END IF;
    IF fn_member_outstanding(p_member_id) >= 100 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unpaid fines of Rs.100 or more; clear fines first';
    END IF;

    IF v_copy_status = 'Reserved' THEN
        SELECT reservation_id INTO v_res FROM reservations
         WHERE book_id = v_book AND member_id = p_member_id AND status = 'Ready' LIMIT 1;
        IF v_res IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Copy is held for another member';
        END IF;
    ELSEIF v_copy_status <> 'Available' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Copy is not available for issue';
    END IF;

    -- close any open reservation this member had for the same title
    UPDATE reservations SET status = 'Fulfilled'
     WHERE book_id = v_book AND member_id = p_member_id AND status IN ('Waiting', 'Ready');

    INSERT INTO issues (copy_id, member_id, issued_by, issue_date, due_date)
    VALUES (p_copy_id, p_member_id, p_staff_id, CURRENT_DATE, DATE_ADD(CURRENT_DATE, INTERVAL v_days DAY));
    SET v_issue = LAST_INSERT_ID();

    COMMIT;
    SELECT v_issue AS issue_id, DATE_ADD(CURRENT_DATE, INTERVAL v_days DAY) AS due_date;
END$$

-- RETURN A BOOK: the trigger trg_issues_after_update does the rest
-- (frees the copy, creates the late fine, promotes the reservation queue).
DROP PROCEDURE IF EXISTS sp_return_book$$
CREATE PROCEDURE sp_return_book(IN p_issue_id INT UNSIGNED, IN p_staff_id INT UNSIGNED)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT status INTO v_status FROM issues WHERE issue_id = p_issue_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Issue record not found';
    ELSEIF v_status <> 'Issued' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This book is already returned or marked lost';
    END IF;

    UPDATE issues SET status = 'Returned', return_date = CURRENT_DATE, received_by = p_staff_id
     WHERE issue_id = p_issue_id;
    COMMIT;

    SELECT i.issue_id, i.return_date, IFNULL(f.amount, 0) AS fine_amount
      FROM issues i LEFT JOIN fines f ON f.issue_id = i.issue_id
     WHERE i.issue_id = p_issue_id;
END$$

DROP PROCEDURE IF EXISTS sp_renew_book$$
CREATE PROCEDURE sp_renew_book(IN p_issue_id INT UNSIGNED)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_due DATE;
    DECLARE v_renew INT;
    DECLARE v_copy INT UNSIGNED;
    DECLARE v_book INT UNSIGNED;
    DECLARE v_days INT;
    DECLARE v_waiting INT DEFAULT 0;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT i.status, i.due_date, i.renew_count, i.copy_id, mp.loan_days
      INTO v_status, v_due, v_renew, v_copy, v_days
      FROM issues i
      JOIN members m ON m.member_id = i.member_id
      JOIN membership_plans mp ON mp.plan_id = m.plan_id
     WHERE i.issue_id = p_issue_id FOR UPDATE;

    IF v_status IS NULL OR v_status <> 'Issued' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only an active loan can be renewed';
    END IF;
    IF v_renew >= 2 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maximum of 2 renewals reached';
    END IF;
    IF v_due < CURRENT_DATE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Overdue books cannot be renewed';
    END IF;

    SELECT book_id INTO v_book FROM book_copies WHERE copy_id = v_copy;
    SELECT COUNT(*) INTO v_waiting FROM reservations WHERE book_id = v_book AND status IN ('Waiting', 'Ready');
    IF v_waiting > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Another member has reserved this book';
    END IF;

    UPDATE issues SET due_date = DATE_ADD(due_date, INTERVAL v_days DAY), renew_count = renew_count + 1
     WHERE issue_id = p_issue_id;
    COMMIT;
    SELECT due_date, renew_count FROM issues WHERE issue_id = p_issue_id;
END$$

DROP PROCEDURE IF EXISTS sp_reserve_book$$
CREATE PROCEDURE sp_reserve_book(IN p_book_id INT UNSIGNED, IN p_member_id INT UNSIGNED)
BEGIN
    DECLARE v_mstatus VARCHAR(20);
    DECLARE v_pos INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT status INTO v_mstatus FROM members WHERE member_id = p_member_id FOR UPDATE;
    IF v_mstatus IS NULL OR v_mstatus <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only active members can reserve books';
    END IF;
    IF fn_available_copies(p_book_id) > 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A copy is available now; no reservation needed';
    END IF;
    IF EXISTS (SELECT 1 FROM reservations WHERE book_id = p_book_id AND member_id = p_member_id
                  AND status IN ('Waiting', 'Ready')) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You already have a reservation for this book';
    END IF;

    INSERT INTO reservations (book_id, member_id) VALUES (p_book_id, p_member_id);
    SELECT COUNT(*) INTO v_pos FROM reservations WHERE book_id = p_book_id AND status = 'Waiting';
    COMMIT;
    SELECT v_pos AS queue_position;
END$$

DROP PROCEDURE IF EXISTS sp_pay_fine$$
CREATE PROCEDURE sp_pay_fine(IN p_fine_id INT UNSIGNED, IN p_amount DECIMAL(8,2),
                             IN p_method VARCHAR(10), IN p_staff_id INT UNSIGNED)
BEGIN
    DECLARE v_amount DECIMAL(8,2);
    DECLARE v_status VARCHAR(10);
    DECLARE v_paid DECIMAL(8,2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT amount, status INTO v_amount, v_status FROM fines WHERE fine_id = p_fine_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Fine not found';
    ELSEIF v_status <> 'Unpaid' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This fine is already settled';
    END IF;

    SELECT IFNULL(SUM(amount), 0) INTO v_paid FROM payments WHERE fine_id = p_fine_id;
    IF p_amount <= 0 OR p_amount > v_amount - v_paid THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid amount: must be positive and not exceed the balance';
    END IF;

    INSERT INTO payments (fine_id, received_by, amount, method)
    VALUES (p_fine_id, p_staff_id, p_amount, p_method);
    COMMIT;

    SELECT status, amount - (v_paid + p_amount) AS balance FROM fines WHERE fine_id = p_fine_id;
END$$

-- STUDENT SELF-REGISTRATION: two inserts that must succeed or fail together (atomicity)
DROP PROCEDURE IF EXISTS sp_register_member$$
CREATE PROCEDURE sp_register_member(IN p_username VARCHAR(40), IN p_password_hash VARCHAR(255),
    IN p_full_name VARCHAR(80), IN p_email VARCHAR(100), IN p_phone VARCHAR(15),
    IN p_plan_id TINYINT UNSIGNED, IN p_branch_id SMALLINT UNSIGNED)
BEGIN
    DECLARE v_user INT UNSIGNED;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    INSERT INTO users (username, password_hash, role_id) VALUES (p_username, p_password_hash, 3);
    SET v_user = LAST_INSERT_ID();
    INSERT INTO members (user_id, plan_id, home_branch_id, full_name, email, phone, join_date, expiry_date)
    VALUES (v_user, p_plan_id, p_branch_id, p_full_name, p_email, p_phone,
            CURRENT_DATE, DATE_ADD(CURRENT_DATE, INTERVAL 1 YEAR));
    COMMIT;
    SELECT member_id FROM members WHERE user_id = v_user;
END$$

-- ---------------------------------------------------------------------
-- TRIGGERS  (Unit 2: integrity / active database rules)
-- The app sets  SET @app_user = 'username'  so the audit trail shows who acted.
-- ---------------------------------------------------------------------

-- T1: business rule guard before an issue row is inserted
DROP TRIGGER IF EXISTS trg_issues_before_insert$$
CREATE TRIGGER trg_issues_before_insert BEFORE INSERT ON issues FOR EACH ROW
BEGIN
    DECLARE v_cstatus VARCHAR(20);
    DECLARE v_mstatus VARCHAR(20);
    SELECT status INTO v_cstatus FROM book_copies WHERE copy_id = NEW.copy_id;
    IF v_cstatus NOT IN ('Available', 'Reserved') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trigger: copy is not available for issue';
    END IF;
    SELECT status INTO v_mstatus FROM members WHERE member_id = NEW.member_id;
    IF v_mstatus <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trigger: member account is not active';
    END IF;
END$$

-- T2: mark the copy as issued and write the audit row
DROP TRIGGER IF EXISTS trg_issues_after_insert$$
CREATE TRIGGER trg_issues_after_insert AFTER INSERT ON issues FOR EACH ROW
BEGIN
    UPDATE book_copies SET status = 'Issued', version = version + 1 WHERE copy_id = NEW.copy_id;
    INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
    VALUES ('issues', NEW.issue_id, 'INSERT',
            JSON_OBJECT('member_id', NEW.member_id, 'copy_id', NEW.copy_id, 'due_date', NEW.due_date),
            COALESCE(@app_user, CURRENT_USER()));
END$$

-- T3: on return or loss: free the copy, create the fine, serve the reservation queue
DROP TRIGGER IF EXISTS trg_issues_after_update$$
CREATE TRIGGER trg_issues_after_update AFTER UPDATE ON issues FOR EACH ROW
BEGIN
    DECLARE v_book INT UNSIGNED;
    DECLARE v_res INT UNSIGNED;
    DECLARE v_rate DECIMAL(6,2);
    DECLARE v_days INT;
    DECLARE v_price DECIMAL(8,2);

    IF NEW.status = 'Returned' AND OLD.status <> 'Returned' THEN
        SELECT book_id INTO v_book FROM book_copies WHERE copy_id = NEW.copy_id;

        SELECT mp.fine_per_day INTO v_rate
          FROM members m JOIN membership_plans mp ON mp.plan_id = m.plan_id
         WHERE m.member_id = NEW.member_id;
        SET v_days = DATEDIFF(NEW.return_date, NEW.due_date);
        IF v_days > 0 THEN
            INSERT INTO fines (issue_id, amount, reason) VALUES (NEW.issue_id, v_days * v_rate, 'Late return')
            ON DUPLICATE KEY UPDATE amount = VALUES(amount);
        END IF;

        SELECT reservation_id INTO v_res FROM reservations
         WHERE book_id = v_book AND status = 'Waiting' ORDER BY reserved_on LIMIT 1;
        IF v_res IS NOT NULL THEN
            UPDATE reservations SET status = 'Ready', expires_on = DATE_ADD(CURRENT_DATE, INTERVAL 3 DAY)
             WHERE reservation_id = v_res;
            UPDATE book_copies SET status = 'Reserved', version = version + 1 WHERE copy_id = NEW.copy_id;
        ELSE
            UPDATE book_copies SET status = 'Available', version = version + 1 WHERE copy_id = NEW.copy_id;
        END IF;

        INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
        VALUES ('issues', NEW.issue_id, 'UPDATE',
                JSON_OBJECT('event', 'returned', 'days_late', GREATEST(v_days, 0)),
                COALESCE(@app_user, CURRENT_USER()));

    ELSEIF NEW.status = 'Lost' AND OLD.status <> 'Lost' THEN
        SELECT bk.price INTO v_price FROM book_copies c JOIN books bk ON bk.book_id = c.book_id
         WHERE c.copy_id = NEW.copy_id;
        UPDATE book_copies SET status = 'Lost', version = version + 1 WHERE copy_id = NEW.copy_id;
        INSERT INTO fines (issue_id, amount, reason) VALUES (NEW.issue_id, v_price, 'Lost book')
        ON DUPLICATE KEY UPDATE amount = VALUES(amount), reason = 'Lost book';
        INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
        VALUES ('issues', NEW.issue_id, 'UPDATE', JSON_OBJECT('event', 'lost'), COALESCE(@app_user, CURRENT_USER()));

    ELSEIF NEW.renew_count > OLD.renew_count THEN
        INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
        VALUES ('issues', NEW.issue_id, 'UPDATE',
                JSON_OBJECT('event', 'renewed', 'new_due_date', NEW.due_date),
                COALESCE(@app_user, CURRENT_USER()));
    END IF;
END$$

-- T4: a payment that covers the whole fine marks it Paid
DROP TRIGGER IF EXISTS trg_payments_after_insert$$
CREATE TRIGGER trg_payments_after_insert AFTER INSERT ON payments FOR EACH ROW
BEGIN
    DECLARE v_fine DECIMAL(8,2);
    DECLARE v_paid DECIMAL(8,2);
    SELECT amount INTO v_fine FROM fines WHERE fine_id = NEW.fine_id;
    SELECT SUM(amount) INTO v_paid FROM payments WHERE fine_id = NEW.fine_id;
    IF v_paid >= v_fine THEN
        UPDATE fines SET status = 'Paid' WHERE fine_id = NEW.fine_id;
    END IF;
    INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
    VALUES ('payments', NEW.payment_id, 'INSERT',
            JSON_OBJECT('fine_id', NEW.fine_id, 'amount', NEW.amount, 'method', NEW.method),
            COALESCE(@app_user, CURRENT_USER()));
END$$

-- T5: only members who actually borrowed a book may review it
DROP TRIGGER IF EXISTS trg_reviews_before_insert$$
CREATE TRIGGER trg_reviews_before_insert BEFORE INSERT ON reviews FOR EACH ROW
BEGIN
    IF NOT EXISTS (SELECT 1 FROM issues i JOIN book_copies c ON c.copy_id = i.copy_id
                    WHERE i.member_id = NEW.member_id AND c.book_id = NEW.book_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Trigger: you can only review books you have borrowed';
    END IF;
END$$

-- T6, T7, T8: audit trail for the catalog
DROP TRIGGER IF EXISTS trg_books_after_insert$$
CREATE TRIGGER trg_books_after_insert AFTER INSERT ON books FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
    VALUES ('books', NEW.book_id, 'INSERT', JSON_OBJECT('title', NEW.title, 'isbn', NEW.isbn),
            COALESCE(@app_user, CURRENT_USER()));
END$$

DROP TRIGGER IF EXISTS trg_books_after_update$$
CREATE TRIGGER trg_books_after_update AFTER UPDATE ON books FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
    VALUES ('books', NEW.book_id, 'UPDATE',
            JSON_OBJECT('old_title', OLD.title, 'new_title', NEW.title, 'old_price', OLD.price, 'new_price', NEW.price),
            COALESCE(@app_user, CURRENT_USER()));
END$$

DROP TRIGGER IF EXISTS trg_books_after_delete$$
CREATE TRIGGER trg_books_after_delete AFTER DELETE ON books FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
    VALUES ('books', OLD.book_id, 'DELETE', JSON_OBJECT('title', OLD.title, 'isbn', OLD.isbn),
            COALESCE(@app_user, CURRENT_USER()));
END$$

-- T9: audit status or plan changes of members
DROP TRIGGER IF EXISTS trg_members_after_update$$
CREATE TRIGGER trg_members_after_update AFTER UPDATE ON members FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status OR OLD.plan_id <> NEW.plan_id THEN
        INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
        VALUES ('members', NEW.member_id, 'UPDATE',
                JSON_OBJECT('old_status', OLD.status, 'new_status', NEW.status,
                            'old_plan', OLD.plan_id, 'new_plan', NEW.plan_id),
                COALESCE(@app_user, CURRENT_USER()));
    END IF;
END$$

-- T10, T11: "not your own parent/boss" rules (cannot be CHECK constraints, see 01_schema.sql)
DROP TRIGGER IF EXISTS trg_staff_before_update$$
CREATE TRIGGER trg_staff_before_update BEFORE UPDATE ON staff FOR EACH ROW
BEGIN
    IF NEW.supervisor_id IS NOT NULL AND NEW.supervisor_id = NEW.staff_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A staff member cannot supervise themselves';
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_categories_before_update$$
CREATE TRIGGER trg_categories_before_update BEFORE UPDATE ON categories FOR EACH ROW
BEGIN
    IF NEW.parent_category_id IS NOT NULL AND NEW.parent_category_id = NEW.category_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A category cannot be its own parent';
    END IF;
END$$

DELIMITER ;

-- =====================================================================
--  QUICK TESTS (run these one by one and take screenshots for the report)
-- =====================================================================
-- SELECT * FROM v_book_catalog LIMIT 5;
-- SELECT * FROM v_overdue_loans;
-- SELECT fn_calc_fine(1), fn_member_outstanding(1), fn_available_copies(1);
-- CALL sp_issue_book(2, 1, 2);             -- success; view the new issue + audit_log
-- CALL sp_issue_book(2, 1, 2);             -- fails: copy is no longer available
-- CALL sp_return_book(<issue_id>, 2);
-- SELECT * FROM audit_log ORDER BY log_id DESC LIMIT 10;
SELECT 'Views' AS object_type, COUNT(*) AS total FROM information_schema.views WHERE table_schema = 'library_db'
UNION ALL SELECT 'Triggers', COUNT(*) FROM information_schema.triggers WHERE trigger_schema = 'library_db'
UNION ALL SELECT 'Procedures', COUNT(*) FROM information_schema.routines WHERE routine_schema = 'library_db' AND routine_type = 'PROCEDURE'
UNION ALL SELECT 'Functions', COUNT(*) FROM information_schema.routines WHERE routine_schema = 'library_db' AND routine_type = 'FUNCTION';

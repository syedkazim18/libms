-- =====================================================================
--  FILE 04: Borrow / Return requests (student applies, librarian approves)
--  Run AFTER 03_programmability.sql.  Adds 1 table, 5 procedures, 2 triggers.
-- =====================================================================
USE library_db;

CREATE TABLE IF NOT EXISTS circulation_requests (
    request_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    member_id     INT UNSIGNED NOT NULL,
    req_type      ENUM('Issue','Return') NOT NULL,
    book_id       INT UNSIGNED NULL,          -- used by Issue requests
    issue_id      INT UNSIGNED NULL,          -- used by Return requests
    status        ENUM('Pending','Approved','Rejected','Cancelled') NOT NULL DEFAULT 'Pending',
    requested_on  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    decided_on    DATETIME NULL,
    decided_by    INT UNSIGNED NULL,
    note          VARCHAR(200) NULL,
    CONSTRAINT pk_requests      PRIMARY KEY (request_id),
    CONSTRAINT fk_req_member    FOREIGN KEY (member_id)  REFERENCES members(member_id),
    CONSTRAINT fk_req_book      FOREIGN KEY (book_id)    REFERENCES books(book_id),
    CONSTRAINT fk_req_issue     FOREIGN KEY (issue_id)   REFERENCES issues(issue_id),
    CONSTRAINT fk_req_staff     FOREIGN KEY (decided_by) REFERENCES staff(staff_id),
    CONSTRAINT ck_req_dates     CHECK (decided_on IS NULL OR decided_on >= requested_on)
) ENGINE=InnoDB;
CREATE INDEX idx_req_status ON circulation_requests (status, requested_on);

DELIMITER $$

DROP PROCEDURE IF EXISTS sp_request_issue$$
CREATE PROCEDURE sp_request_issue(IN p_member_id INT UNSIGNED, IN p_book_id INT UNSIGNED)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_expiry DATE;
    DECLARE v_max INT;
    DECLARE v_open INT DEFAULT 0;
    DECLARE v_pend INT DEFAULT 0;
    SELECT m.status, m.expiry_date, mp.max_books INTO v_status, v_expiry, v_max
      FROM members m JOIN membership_plans mp ON mp.plan_id = m.plan_id WHERE m.member_id = p_member_id;
    IF v_status IS NULL OR v_status <> 'Active' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only active members can request books';
    END IF;
    IF v_expiry < CURRENT_DATE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Membership has expired';
    END IF;
    IF fn_available_copies(p_book_id) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No copy is free right now; please reserve the book instead';
    END IF;
    IF EXISTS (SELECT 1 FROM circulation_requests WHERE member_id = p_member_id AND book_id = p_book_id
                  AND req_type = 'Issue' AND status = 'Pending') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You already have a pending request for this book';
    END IF;
    SELECT COUNT(*) INTO v_open FROM issues WHERE member_id = p_member_id AND status = 'Issued';
    SELECT COUNT(*) INTO v_pend FROM circulation_requests
     WHERE member_id = p_member_id AND req_type = 'Issue' AND status = 'Pending';
    IF v_open + v_pend >= v_max THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borrowing limit reached (including pending requests)';
    END IF;
    INSERT INTO circulation_requests (member_id, req_type, book_id) VALUES (p_member_id, 'Issue', p_book_id);
    SELECT LAST_INSERT_ID() AS request_id;
END$$

DROP PROCEDURE IF EXISTS sp_request_return$$
CREATE PROCEDURE sp_request_return(IN p_member_id INT UNSIGNED, IN p_issue_id INT UNSIGNED)
BEGIN
    DECLARE v_owner INT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    SELECT member_id, status INTO v_owner, v_status FROM issues WHERE issue_id = p_issue_id;
    IF v_owner IS NULL OR v_owner <> p_member_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Loan not found for this member';
    END IF;
    IF v_status <> 'Issued' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This book is already returned';
    END IF;
    IF EXISTS (SELECT 1 FROM circulation_requests WHERE issue_id = p_issue_id AND req_type = 'Return' AND status = 'Pending') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A return request is already pending';
    END IF;
    INSERT INTO circulation_requests (member_id, req_type, issue_id) VALUES (p_member_id, 'Return', p_issue_id);
    SELECT LAST_INSERT_ID() AS request_id;
END$$

-- Approval reuses the safe, transactional sp_issue_book / sp_return_book
DROP PROCEDURE IF EXISTS sp_approve_request$$
CREATE PROCEDURE sp_approve_request(IN p_request_id INT UNSIGNED, IN p_staff_id INT UNSIGNED)
BEGIN
    DECLARE v_type VARCHAR(10);
    DECLARE v_status VARCHAR(10);
    DECLARE v_member, v_book, v_issue, v_copy INT UNSIGNED;
    SELECT req_type, status, member_id, book_id, issue_id INTO v_type, v_status, v_member, v_book, v_issue
      FROM circulation_requests WHERE request_id = p_request_id;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Request not found';
    ELSEIF v_status <> 'Pending' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This request was already decided';
    END IF;
    IF v_type = 'Issue' THEN
        SELECT copy_id INTO v_copy FROM book_copies WHERE book_id = v_book AND status = 'Available' ORDER BY copy_id LIMIT 1;
        IF v_copy IS NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No copy is available now; reject the request or reserve for the member';
        END IF;
        CALL sp_issue_book(v_member, v_copy, p_staff_id);
    ELSE
        CALL sp_return_book(v_issue, p_staff_id);
    END IF;
    UPDATE circulation_requests SET status = 'Approved', decided_on = NOW(), decided_by = p_staff_id
     WHERE request_id = p_request_id;
END$$

DROP PROCEDURE IF EXISTS sp_reject_request$$
CREATE PROCEDURE sp_reject_request(IN p_request_id INT UNSIGNED, IN p_staff_id INT UNSIGNED, IN p_note VARCHAR(200))
BEGIN
    UPDATE circulation_requests SET status = 'Rejected', decided_on = NOW(), decided_by = p_staff_id, note = p_note
     WHERE request_id = p_request_id AND status = 'Pending';
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Request not found or already decided';
    END IF;
END$$

DROP PROCEDURE IF EXISTS sp_cancel_request$$
CREATE PROCEDURE sp_cancel_request(IN p_request_id INT UNSIGNED, IN p_member_id INT UNSIGNED)
BEGIN
    UPDATE circulation_requests SET status = 'Cancelled', decided_on = NOW()
     WHERE request_id = p_request_id AND member_id = p_member_id AND status = 'Pending';
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Request not found or already decided';
    END IF;
END$$

DROP TRIGGER IF EXISTS trg_requests_after_insert$$
CREATE TRIGGER trg_requests_after_insert AFTER INSERT ON circulation_requests FOR EACH ROW
BEGIN
    INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
    VALUES ('circulation_requests', NEW.request_id, 'INSERT',
            JSON_OBJECT('type', NEW.req_type, 'member_id', NEW.member_id), COALESCE(@app_user, CURRENT_USER()));
END$$

DROP TRIGGER IF EXISTS trg_requests_after_update$$
CREATE TRIGGER trg_requests_after_update AFTER UPDATE ON circulation_requests FOR EACH ROW
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO audit_log (table_name, record_id, action, details, changed_by)
        VALUES ('circulation_requests', NEW.request_id, 'UPDATE',
                JSON_OBJECT('type', NEW.req_type, 'from', OLD.status, 'to', NEW.status), COALESCE(@app_user, CURRENT_USER()));
    END IF;
END$$
DELIMITER ;

SELECT COUNT(*) AS request_rows FROM circulation_requests;

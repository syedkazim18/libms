-- =====================================================================
--  LIBRARY MANAGEMENT SYSTEM  |  FILE 01: DDL (Schema)
--  Database : MySQL 8.0.16+ (CHECK constraints are enforced from 8.0.16)
--  Run      : mysql -u root -p < 01_schema.sql
-- =====================================================================

DROP DATABASE IF EXISTS library_db;
CREATE DATABASE library_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE library_db;

-- ---------------------------------------------------------------------
-- 1. ROLES  (admin / librarian / student)
-- ---------------------------------------------------------------------
CREATE TABLE roles (
    role_id      TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    role_name    VARCHAR(20)  NOT NULL,
    description  VARCHAR(100) NULL,
    CONSTRAINT pk_roles      PRIMARY KEY (role_id),
    CONSTRAINT uq_role_name  UNIQUE (role_name)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 2. USERS  (login accounts; password stored as a hash, never plain text)
-- ---------------------------------------------------------------------
CREATE TABLE users (
    user_id        INT UNSIGNED NOT NULL AUTO_INCREMENT,
    username       VARCHAR(40)  NOT NULL,
    password_hash  VARCHAR(255) NOT NULL,
    role_id        TINYINT UNSIGNED NOT NULL,
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_login     DATETIME     NULL,
    CONSTRAINT pk_users       PRIMARY KEY (user_id),
    CONSTRAINT uq_username    UNIQUE (username),
    CONSTRAINT fk_users_role  FOREIGN KEY (role_id) REFERENCES roles(role_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_username_len CHECK (CHAR_LENGTH(username) >= 4)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 3. MEMBERSHIP_PLANS  (rules live here, not repeated in every member row -> 3NF)
-- ---------------------------------------------------------------------
CREATE TABLE membership_plans (
    plan_id       TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    plan_name     VARCHAR(30)  NOT NULL,
    max_books     TINYINT UNSIGNED NOT NULL,
    loan_days     TINYINT UNSIGNED NOT NULL DEFAULT 14,
    fine_per_day  DECIMAL(6,2) NOT NULL DEFAULT 2.00,
    annual_fee    DECIMAL(8,2) NOT NULL DEFAULT 0.00,
    CONSTRAINT pk_plans        PRIMARY KEY (plan_id),
    CONSTRAINT uq_plan_name    UNIQUE (plan_name),
    CONSTRAINT ck_plan_books   CHECK (max_books > 0),
    CONSTRAINT ck_plan_days    CHECK (loan_days BETWEEN 1 AND 90),
    CONSTRAINT ck_plan_fine    CHECK (fine_per_day >= 0),
    CONSTRAINT ck_plan_fee     CHECK (annual_fee >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 4. BRANCHES  (multi-branch library -> useful for distributed DB discussion)
-- ---------------------------------------------------------------------
CREATE TABLE branches (
    branch_id    SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    branch_code  CHAR(3)      NOT NULL,
    branch_name  VARCHAR(60)  NOT NULL,
    city         VARCHAR(40)  NOT NULL,
    address      VARCHAR(150) NULL,
    phone        VARCHAR(15)  NULL,
    opened_on    DATE         NULL,
    CONSTRAINT pk_branches     PRIMARY KEY (branch_id),
    CONSTRAINT uq_branch_code  UNIQUE (branch_code),
    CONSTRAINT uq_branch_name  UNIQUE (branch_name)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 5. SHELVES  (created to reach BCNF: shelf_code -> branch_id, see normalization doc)
-- ---------------------------------------------------------------------
CREATE TABLE shelves (
    shelf_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    shelf_code  VARCHAR(10)  NOT NULL,
    branch_id   SMALLINT UNSIGNED NOT NULL,
    section     VARCHAR(40)  NULL,
    CONSTRAINT pk_shelves       PRIMARY KEY (shelf_id),
    CONSTRAINT uq_shelf_code    UNIQUE (shelf_code),
    CONSTRAINT fk_shelf_branch  FOREIGN KEY (branch_id) REFERENCES branches(branch_id)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 6. STAFF  (self-referencing FK: supervisor_id -> staff_id)
-- ---------------------------------------------------------------------
CREATE TABLE staff (
    staff_id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id        INT UNSIGNED NOT NULL,
    branch_id      SMALLINT UNSIGNED NOT NULL,
    supervisor_id  INT UNSIGNED NULL,
    full_name      VARCHAR(80)  NOT NULL,
    designation    VARCHAR(40)  NOT NULL,
    email          VARCHAR(100) NOT NULL,
    phone          VARCHAR(15)  NULL,
    salary         DECIMAL(10,2) NOT NULL,
    hire_date      DATE         NOT NULL,
    CONSTRAINT pk_staff         PRIMARY KEY (staff_id),
    CONSTRAINT uq_staff_user    UNIQUE (user_id),
    CONSTRAINT uq_staff_email   UNIQUE (email),
    CONSTRAINT fk_staff_user    FOREIGN KEY (user_id)       REFERENCES users(user_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_staff_branch  FOREIGN KEY (branch_id)     REFERENCES branches(branch_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_staff_boss    FOREIGN KEY (supervisor_id) REFERENCES staff(staff_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT ck_staff_salary  CHECK (salary > 0)
    -- 'supervisor <> self' rule is enforced by trigger trg_staff_before_update (MySQL error 3823:
    -- a column used in a FK with SET NULL/CASCADE cannot appear in a CHECK)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 7. MEMBERS
-- ---------------------------------------------------------------------
CREATE TABLE members (
    member_id        INT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id          INT UNSIGNED NOT NULL,
    plan_id          TINYINT UNSIGNED NOT NULL,
    home_branch_id   SMALLINT UNSIGNED NOT NULL,
    full_name        VARCHAR(80)  NOT NULL,
    email            VARCHAR(100) NOT NULL,
    phone            VARCHAR(15)  NULL,
    address          VARCHAR(150) NULL,
    dob              DATE         NULL,
    join_date        DATE         NOT NULL DEFAULT (CURRENT_DATE),
    expiry_date      DATE         NOT NULL,
    status           ENUM('Active','Suspended','Expired') NOT NULL DEFAULT 'Active',
    CONSTRAINT pk_members        PRIMARY KEY (member_id),
    CONSTRAINT uq_member_user    UNIQUE (user_id),
    CONSTRAINT uq_member_email   UNIQUE (email),
    CONSTRAINT fk_member_user    FOREIGN KEY (user_id)        REFERENCES users(user_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_member_plan    FOREIGN KEY (plan_id)        REFERENCES membership_plans(plan_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_member_branch  FOREIGN KEY (home_branch_id) REFERENCES branches(branch_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_member_dates   CHECK (expiry_date > join_date),
    CONSTRAINT ck_member_email   CHECK (email LIKE '%_@_%.__%')
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 8-11. LOOKUP TABLES: authors, publishers, categories (self-ref), languages
-- ---------------------------------------------------------------------
CREATE TABLE authors (
    author_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    full_name    VARCHAR(80)  NOT NULL,
    nationality  VARCHAR(40)  NULL,
    birth_year   SMALLINT     NULL,
    bio          TEXT         NULL,
    CONSTRAINT pk_authors     PRIMARY KEY (author_id),
    CONSTRAINT uq_author_name UNIQUE (full_name),
    CONSTRAINT ck_author_year CHECK (birth_year IS NULL OR birth_year BETWEEN 1000 AND 2100)
) ENGINE=InnoDB;

CREATE TABLE publishers (
    publisher_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
    name         VARCHAR(80)  NOT NULL,
    city         VARCHAR(40)  NULL,
    country      VARCHAR(40)  NOT NULL DEFAULT 'India',
    website      VARCHAR(120) NULL,
    CONSTRAINT pk_publishers  PRIMARY KEY (publisher_id),
    CONSTRAINT uq_publisher   UNIQUE (name)
) ENGINE=InnoDB;

CREATE TABLE categories (
    category_id         INT UNSIGNED NOT NULL AUTO_INCREMENT,
    name                VARCHAR(50) NOT NULL,
    parent_category_id  INT UNSIGNED NULL,          -- self-referencing FK (hierarchy)
    CONSTRAINT pk_categories  PRIMARY KEY (category_id),
    CONSTRAINT uq_category    UNIQUE (name),
    CONSTRAINT fk_cat_parent  FOREIGN KEY (parent_category_id) REFERENCES categories(category_id)
        ON UPDATE CASCADE ON DELETE SET NULL
    -- 'parent <> self' rule is enforced by trigger trg_categories_before_update
) ENGINE=InnoDB;

CREATE TABLE languages (
    language_id  TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name         VARCHAR(30) NOT NULL,
    iso_code     CHAR(2)     NOT NULL,
    CONSTRAINT pk_languages   PRIMARY KEY (language_id),
    CONSTRAINT uq_lang_name   UNIQUE (name),
    CONSTRAINT uq_lang_iso    UNIQUE (iso_code)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 12. BOOKS  (a "title"; physical items live in book_copies)
-- ---------------------------------------------------------------------
CREATE TABLE books (
    book_id           INT UNSIGNED NOT NULL AUTO_INCREMENT,
    isbn              CHAR(13)     NOT NULL,
    title             VARCHAR(200) NOT NULL,
    publisher_id      INT UNSIGNED NOT NULL,
    language_id       TINYINT UNSIGNED NOT NULL,
    publication_year  SMALLINT     NOT NULL,
    edition           TINYINT UNSIGNED NOT NULL DEFAULT 1,
    pages             SMALLINT UNSIGNED NULL,
    price             DECIMAL(8,2) NOT NULL,
    description       TEXT         NULL,
    ebook_url         VARCHAR(255) NULL,           -- digital library link
    created_at        DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_books        PRIMARY KEY (book_id),
    CONSTRAINT uq_book_isbn    UNIQUE (isbn),
    CONSTRAINT fk_book_pub     FOREIGN KEY (publisher_id) REFERENCES publishers(publisher_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_book_lang    FOREIGN KEY (language_id)  REFERENCES languages(language_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_book_year    CHECK (publication_year BETWEEN 1450 AND 2100),
    CONSTRAINT ck_book_price   CHECK (price >= 0),
    CONSTRAINT ck_book_pages   CHECK (pages IS NULL OR pages > 0),
    CONSTRAINT ck_book_isbn    CHECK (isbn REGEXP '^[0-9]{13}$')
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 13-14. M:N BRIDGE TABLES  (composite primary keys; this is what 4NF requires)
-- ---------------------------------------------------------------------
CREATE TABLE book_authors (
    book_id       INT UNSIGNED NOT NULL,
    author_id     INT UNSIGNED NOT NULL,
    author_order  TINYINT UNSIGNED NOT NULL DEFAULT 1,
    CONSTRAINT pk_book_authors PRIMARY KEY (book_id, author_id),
    CONSTRAINT fk_ba_book      FOREIGN KEY (book_id)   REFERENCES books(book_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_ba_author    FOREIGN KEY (author_id) REFERENCES authors(author_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT ck_ba_order     CHECK (author_order > 0)
) ENGINE=InnoDB;

CREATE TABLE book_categories (
    book_id      INT UNSIGNED NOT NULL,
    category_id  INT UNSIGNED NOT NULL,
    CONSTRAINT pk_book_categories PRIMARY KEY (book_id, category_id),
    CONSTRAINT fk_bc_book     FOREIGN KEY (book_id)     REFERENCES books(book_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_bc_category FOREIGN KEY (category_id) REFERENCES categories(category_id)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 15. BOOK_COPIES  (physical copies; `version` supports optimistic concurrency)
-- ---------------------------------------------------------------------
CREATE TABLE book_copies (
    copy_id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    book_id       INT UNSIGNED NOT NULL,
    shelf_id      INT UNSIGNED NOT NULL,
    barcode       VARCHAR(20)  NOT NULL,
    status        ENUM('Available','Issued','Reserved','Lost','Damaged') NOT NULL DEFAULT 'Available',
    acquired_on   DATE         NOT NULL DEFAULT (CURRENT_DATE),
    version       INT UNSIGNED NOT NULL DEFAULT 1,
    updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_copies       PRIMARY KEY (copy_id),
    CONSTRAINT uq_copy_barcode UNIQUE (barcode),
    CONSTRAINT fk_copy_book    FOREIGN KEY (book_id)  REFERENCES books(book_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_copy_shelf   FOREIGN KEY (shelf_id) REFERENCES shelves(shelf_id)
        ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 16. ISSUES  (the circulation transaction table)
-- ---------------------------------------------------------------------
CREATE TABLE issues (
    issue_id       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    copy_id        INT UNSIGNED NOT NULL,
    member_id      INT UNSIGNED NOT NULL,
    issued_by      INT UNSIGNED NOT NULL,
    received_by    INT UNSIGNED NULL,
    issue_date     DATE NOT NULL DEFAULT (CURRENT_DATE),
    due_date       DATE NOT NULL,
    return_date    DATE NULL,
    renew_count    TINYINT UNSIGNED NOT NULL DEFAULT 0,
    status         ENUM('Issued','Returned','Lost') NOT NULL DEFAULT 'Issued',
    CONSTRAINT pk_issues        PRIMARY KEY (issue_id),
    CONSTRAINT fk_issue_copy    FOREIGN KEY (copy_id)     REFERENCES book_copies(copy_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_issue_member  FOREIGN KEY (member_id)   REFERENCES members(member_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_issue_by      FOREIGN KEY (issued_by)   REFERENCES staff(staff_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_issue_recv    FOREIGN KEY (received_by) REFERENCES staff(staff_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT ck_issue_due     CHECK (due_date >= issue_date),
    CONSTRAINT ck_issue_return  CHECK (return_date IS NULL OR return_date >= issue_date),
    CONSTRAINT ck_issue_renew   CHECK (renew_count <= 2),
    CONSTRAINT ck_issue_state   CHECK ((status = 'Returned' AND return_date IS NOT NULL)
                                    OR (status <> 'Returned'))
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 17. RESERVATIONS  (queue for a title, not a specific copy)
-- ---------------------------------------------------------------------
CREATE TABLE reservations (
    reservation_id  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    book_id         INT UNSIGNED NOT NULL,
    member_id       INT UNSIGNED NOT NULL,
    reserved_on     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_on      DATE NULL,
    status          ENUM('Waiting','Ready','Fulfilled','Cancelled','Expired') NOT NULL DEFAULT 'Waiting',
    CONSTRAINT pk_reservations  PRIMARY KEY (reservation_id),
    CONSTRAINT fk_res_book      FOREIGN KEY (book_id)   REFERENCES books(book_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_res_member    FOREIGN KEY (member_id) REFERENCES members(member_id)
        ON UPDATE CASCADE ON DELETE CASCADE
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 18. FINES  (one fine per issue; created by trigger on late return)
-- ---------------------------------------------------------------------
CREATE TABLE fines (
    fine_id      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    issue_id     INT UNSIGNED NOT NULL,
    amount       DECIMAL(8,2) NOT NULL,
    reason       ENUM('Late return','Lost book','Damaged book') NOT NULL DEFAULT 'Late return',
    status       ENUM('Unpaid','Paid','Waived') NOT NULL DEFAULT 'Unpaid',
    assessed_on  DATE NOT NULL DEFAULT (CURRENT_DATE),
    CONSTRAINT pk_fines        PRIMARY KEY (fine_id),
    CONSTRAINT uq_fine_issue   UNIQUE (issue_id),
    CONSTRAINT fk_fine_issue   FOREIGN KEY (issue_id) REFERENCES issues(issue_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT ck_fine_amount  CHECK (amount >= 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 19. PAYMENTS
-- ---------------------------------------------------------------------
CREATE TABLE payments (
    payment_id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
    fine_id      INT UNSIGNED NOT NULL,
    received_by  INT UNSIGNED NULL,
    amount       DECIMAL(8,2) NOT NULL,
    method       ENUM('Cash','UPI','Card') NOT NULL DEFAULT 'Cash',
    paid_on      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_payments     PRIMARY KEY (payment_id),
    CONSTRAINT fk_pay_fine     FOREIGN KEY (fine_id)     REFERENCES fines(fine_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT fk_pay_staff    FOREIGN KEY (received_by) REFERENCES staff(staff_id)
        ON UPDATE CASCADE ON DELETE SET NULL,
    CONSTRAINT ck_pay_amount   CHECK (amount > 0)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 20. REVIEWS  (one review per member per book -> composite UNIQUE)
-- ---------------------------------------------------------------------
CREATE TABLE reviews (
    review_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    book_id      INT UNSIGNED NOT NULL,
    member_id    INT UNSIGNED NOT NULL,
    rating       TINYINT UNSIGNED NOT NULL,
    comment      VARCHAR(500) NULL,
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_reviews      PRIMARY KEY (review_id),
    CONSTRAINT uq_review_once  UNIQUE (book_id, member_id),
    CONSTRAINT fk_rev_book     FOREIGN KEY (book_id)   REFERENCES books(book_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_rev_member   FOREIGN KEY (member_id) REFERENCES members(member_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT ck_rev_rating   CHECK (rating BETWEEN 1 AND 5)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- 21. AUDIT_LOG  (filled automatically by triggers; no FKs on purpose so that
--     history survives even when the original row is deleted)
-- ---------------------------------------------------------------------
CREATE TABLE audit_log (
    log_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    table_name  VARCHAR(40) NOT NULL,
    record_id   INT UNSIGNED NOT NULL,
    action      ENUM('INSERT','UPDATE','DELETE') NOT NULL,
    details     JSON NULL,
    changed_by  VARCHAR(80) NOT NULL DEFAULT 'system',
    changed_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_audit PRIMARY KEY (log_id)
) ENGINE=InnoDB;

-- ---------------------------------------------------------------------
-- Indexes that the application needs (more are added in file 05 for the
-- query-optimization demo so you can show EXPLAIN before and after).
-- ---------------------------------------------------------------------
CREATE INDEX idx_issues_member   ON issues (member_id, status);
CREATE INDEX idx_issues_due      ON issues (status, due_date);
CREATE INDEX idx_copies_book     ON book_copies (book_id, status);
CREATE INDEX idx_res_book        ON reservations (book_id, status);

-- Quick check
SHOW TABLES;

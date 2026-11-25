CREATE DATABASE credit_bank CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE credit_bank;
SET NAMES utf8mb4;


CREATE TABLE ownership_type (
    ownership_type_id INT AUTO_INCREMENT PRIMARY KEY,
    name              VARCHAR(100) NOT NULL UNIQUE
) ENGINE = InnoDB;

CREATE TABLE client (
    client_id           INT AUTO_INCREMENT PRIMARY KEY,
    name                VARCHAR(200) NOT NULL,
    ownership_type_id   INT          NOT NULL,
    address             VARCHAR(255) NOT NULL,
    phone               VARCHAR(20)  NOT NULL,
    contact_last_name   VARCHAR(60)  NOT NULL,
    contact_first_name  VARCHAR(60)  NOT NULL,
    contact_middle_name VARCHAR(60)  NULL,
    FOREIGN KEY (ownership_type_id)
        REFERENCES ownership_type (ownership_type_id)
) ENGINE = InnoDB;

CREATE TABLE credit_type (
    credit_type_id INT AUTO_INCREMENT PRIMARY KEY,
    name           VARCHAR(100) NOT NULL UNIQUE,
    conditions     TEXT         NOT NULL,
    annual_rate    DECIMAL(5,2) NOT NULL, 
    term_days      INT          NOT NULL,
    penalty_rate   DECIMAL(5,3) NOT NULL,
    CHECK (term_days > 0),
    CHECK (penalty_rate >= 0)
) ENGINE = InnoDB;

CREATE TABLE credit (
    credit_id      INT AUTO_INCREMENT PRIMARY KEY,
    client_id      INT           NOT NULL,
    credit_type_id INT           NOT NULL,
    amount         DECIMAL(15,2) NOT NULL,
    issue_date     DATE          NOT NULL,
    CHECK (amount > 0),
    FOREIGN KEY (client_id)      REFERENCES client (client_id),
    FOREIGN KEY (credit_type_id) REFERENCES credit_type (credit_type_id)
) ENGINE = InnoDB;

CREATE TABLE repayment (
    credit_id      INT           NOT NULL,
    payment_no     INT           NOT NULL,
    payment_date   DATE          NOT NULL,
    payment_amount DECIMAL(15,2) NOT NULL,
    penalty_amount DECIMAL(15,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (credit_id, payment_no),
    CHECK (payment_no > 0),
    CHECK (payment_amount > 0),
    CHECK (penalty_amount >= 0),
    FOREIGN KEY (credit_id) REFERENCES credit (credit_id)
) ENGINE = InnoDB;

DELIMITER //

CREATE TRIGGER trg_repayment_before_insert
BEFORE INSERT ON repayment
FOR EACH ROW
BEGIN
    DECLARE v_amount       DECIMAL(15,2);
    DECLARE v_issue_date   DATE;
    DECLARE v_term_days    INT;
    DECLARE v_penalty_rate DECIMAL(5,3);
    DECLARE v_paid         DECIMAL(15,2);
    DECLARE v_days_late    INT;

    SELECT c.amount, c.issue_date, t.term_days, t.penalty_rate
      INTO v_amount, v_issue_date, v_term_days, v_penalty_rate
      FROM credit c
      JOIN credit_type t ON t.credit_type_id = c.credit_type_id
     WHERE c.credit_id = NEW.credit_id;

    IF NEW.payment_date < v_issue_date THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Дата платежу раніша за дату видачі кредиту';
    END IF;

    SELECT COALESCE(SUM(payment_amount), 0)
      INTO v_paid
      FROM repayment
     WHERE credit_id = NEW.credit_id;

    IF v_paid + NEW.payment_amount > v_amount THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Платіж перевищує залишок боргу';
    END IF;

    SET v_days_late = GREATEST(
        DATEDIFF(NEW.payment_date,
                 DATE_ADD(v_issue_date, INTERVAL v_term_days DAY)),
        0);

    SET NEW.penalty_amount = ROUND(
        NEW.payment_amount * v_penalty_rate / 100 * v_days_late, 2);
END//

DELIMITER ;

INSERT INTO ownership_type (ownership_type_id, name) VALUES
    (1, 'Приватна'),
    (2, 'Державна'),
    (3, 'Колективна');

INSERT INTO client (client_id, name, ownership_type_id, address, phone,
                    contact_last_name, contact_first_name, contact_middle_name) VALUES
    (1, 'ТОВ "Приклад-Агро"',  1, 'м. Прикладне, вул. Садова, 1', '+000000000001',
        'Іваненко', 'Петро', 'Олегович'),
    (2, 'ДП "Зразок-Транс"',   2, 'м. Прикладне, вул. Лісова, 7', '+000000000002',
        'Коваль', 'Ірина', 'Василівна'),
    (3, 'Кооператив "Тест"',   3, 'м. Прикладне, вул. Польова, 3', '+000000000003',
        'Мельник', 'Андрій', NULL);

INSERT INTO credit_type (credit_type_id, name, conditions, annual_rate,
                         term_days, penalty_rate) VALUES
    (1, 'Короткостроковий', 'Фінансовий звіт за останній квартал', 18.00,  90, 0.200),
    (2, 'Оборотний',        'Застава товарів в обороті',           16.00, 180, 0.100),
    (3, 'Інвестиційний',    'Бізнес-план та застава майна',        14.00, 365, 0.050);

INSERT INTO credit (credit_id, client_id, credit_type_id, amount, issue_date) VALUES
    (1, 1, 2, 100000.00, '2026-03-01'),
    (2, 2, 3, 500000.00, '2026-04-10'),
    (3, 3, 1,  60000.00, '2026-05-01');

INSERT INTO repayment (credit_id, payment_no, payment_date, payment_amount)
VALUES (1, 1, '2026-06-01', 40000.00);
INSERT INTO repayment (credit_id, payment_no, payment_date, payment_amount)
VALUES (1, 2, '2026-08-28', 35000.00);
INSERT INTO repayment (credit_id, payment_no, payment_date, payment_amount)
VALUES (1, 3, '2026-09-07', 25000.00);   -- 10 днів прострочення, штраф 250.00
INSERT INTO repayment (credit_id, payment_no, payment_date, payment_amount)
VALUES (2, 1, '2026-10-10', 120000.00);
INSERT INTO repayment (credit_id, payment_no, payment_date, payment_amount)
VALUES (3, 1, '2026-07-15', 20000.00);


CREATE VIEW v_credit_status AS
SELECT
    s.*,
    CASE WHEN s.balance > 0
         THEN GREATEST(DATEDIFF(CURDATE(), s.due_date), 0)
         ELSE 0
    END AS days_overdue,
    ROUND(s.balance * s.penalty_rate / 100
          * GREATEST(DATEDIFF(CURDATE(), s.due_date), 0), 2) AS unpaid_penalty
FROM (
    SELECT
        c.credit_id,
        cl.name AS client_name,
        t.name  AS credit_type_name,
        c.amount,
        c.issue_date,
        DATE_ADD(c.issue_date, INTERVAL t.term_days DAY) AS due_date,
        t.penalty_rate,
        COALESCE(p.paid, 0)               AS paid,
        c.amount - COALESCE(p.paid, 0)    AS balance,
        COALESCE(p.fixed_penalty, 0)      AS fixed_penalty
    FROM credit c
    JOIN client cl      ON cl.client_id = c.client_id
    JOIN credit_type t  ON t.credit_type_id = c.credit_type_id
    LEFT JOIN (
        SELECT credit_id,
               SUM(payment_amount) AS paid,
               SUM(penalty_amount) AS fixed_penalty
        FROM repayment
        GROUP BY credit_id
    ) p ON p.credit_id = c.credit_id
) s;

SELECT * FROM v_credit_status ORDER BY credit_id;

SELECT credit_id, client_name, due_date, balance, days_overdue, unpaid_penalty
FROM v_credit_status
WHERE days_overdue > 0
ORDER BY days_overdue DESC;

SELECT payment_no, payment_date, payment_amount, penalty_amount,
       SUM(payment_amount) OVER (ORDER BY payment_no) AS paid_total
FROM repayment
WHERE credit_id = 1
ORDER BY payment_no;

SELECT t.name,
       COUNT(c.credit_id)         AS credits_count,
       COALESCE(SUM(c.amount), 0) AS total_amount
FROM credit_type t
LEFT JOIN credit c ON c.credit_type_id = t.credit_type_id
GROUP BY t.credit_type_id, t.name
ORDER BY total_amount DESC;

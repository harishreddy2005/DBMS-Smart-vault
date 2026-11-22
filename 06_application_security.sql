-- SmartVault migration: real authentication, two application database roles,
-- recursive categories, and controlled transactional entry points.
-- Run as database owner AFTER 01_schema.sql and 02_sample_data.sql.
BEGIN;
SET search_path TO smartvault, public;
ALTER TABLE app_users ADD COLUMN IF NOT EXISTS password_hash text;
ALTER TABLE categories ADD COLUMN IF NOT EXISTS parent_category_id integer REFERENCES categories(category_id);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='smartvault_admin') THEN CREATE ROLE smartvault_admin NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='smartvault_staff') THEN CREATE ROLE smartvault_staff NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='smartvault_auth') THEN CREATE ROLE smartvault_auth NOLOGIN; END IF;
END $$;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA smartvault FROM PUBLIC;
GRANT USAGE ON SCHEMA smartvault TO smartvault_admin,smartvault_staff,smartvault_auth;

CREATE OR REPLACE FUNCTION prevent_category_cycle() RETURNS trigger LANGUAGE plpgsql
SET search_path=smartvault,pg_temp AS $$
BEGIN
 IF NEW.parent_category_id=NEW.category_id OR (NEW.parent_category_id IS NOT NULL AND EXISTS (
  WITH RECURSIVE ancestors AS (
   SELECT category_id,parent_category_id,ARRAY[category_id] AS visited FROM categories WHERE category_id=NEW.parent_category_id
   UNION ALL SELECT c.category_id,c.parent_category_id,a.visited||c.category_id FROM categories c
   JOIN ancestors a ON c.category_id=a.parent_category_id WHERE NOT c.category_id=ANY(a.visited)
  ) SELECT 1 FROM ancestors WHERE category_id=NEW.category_id
 )) THEN RAISE EXCEPTION 'A category cannot be its own ancestor'; END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS category_cycle_guard ON categories;
CREATE TRIGGER category_cycle_guard BEFORE INSERT OR UPDATE OF parent_category_id ON categories
FOR EACH ROW EXECUTE FUNCTION prevent_category_cycle();

CREATE OR REPLACE FUNCTION login_record(p_email text)
RETURNS TABLE(user_id integer,full_name varchar,email varchar,role varchar,password_hash text)
LANGUAGE sql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
 SELECT u.user_id,u.full_name,u.email,u.role,u.password_hash FROM app_users u WHERE lower(u.email)=lower(p_email);
$$;
CREATE OR REPLACE FUNCTION get_session_user(p_id integer)
RETURNS TABLE(user_id integer,full_name varchar,email varchar,role varchar)
LANGUAGE sql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
 SELECT u.user_id,u.full_name,u.email,u.role FROM app_users u WHERE u.user_id=p_id;
$$;
CREATE OR REPLACE FUNCTION check_actor(p_actor integer) RETURNS void
LANGUAGE plpgsql SET search_path=smartvault,pg_temp AS $$
DECLARE actor_role text;
BEGIN
 SELECT role INTO actor_role FROM app_users WHERE user_id=p_actor;
 IF actor_role IS NULL THEN RAISE EXCEPTION 'User does not exist'; END IF;
 IF (session_user='smartvault_staff' AND actor_role<>'STAFF') OR
    (session_user='smartvault_admin' AND actor_role<>'ADMIN') THEN
  RAISE EXCEPTION 'Actor role does not match the database connection role';
 END IF;
END $$;
CREATE OR REPLACE FUNCTION record_movement(p_product integer,p_source integer,p_destination integer,
 p_type text,p_quantity integer,p_actor integer,p_note text DEFAULT '') RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
DECLARE result_id integer;
BEGIN
 PERFORM check_actor(p_actor);
 INSERT INTO stock_movements(product_id,source_warehouse_id,destination_warehouse_id,movement_type,quantity,performed_by,note)
 VALUES(p_product,p_source,p_destination,p_type,p_quantity,p_actor,left(p_note,200))
 RETURNING movement_id INTO result_id;
 RETURN result_id;
END $$;
CREATE OR REPLACE FUNCTION create_purchase_order(p_supplier integer,p_warehouse integer,p_actor integer,p_items jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
DECLARE result_id integer; line jsonb;
BEGIN
 PERFORM check_actor(p_actor);
 IF p_items IS NULL OR jsonb_typeof(p_items)<>'array' OR jsonb_array_length(p_items)<1 OR jsonb_array_length(p_items)>100
 THEN RAISE EXCEPTION 'An order must contain 1 to 100 items'; END IF;
 INSERT INTO purchase_orders(supplier_id,warehouse_id,created_by,order_date,status)
 VALUES(p_supplier,p_warehouse,p_actor,CURRENT_DATE,'PLACED') RETURNING order_id INTO result_id;
 FOR line IN SELECT * FROM jsonb_array_elements(p_items) LOOP
  INSERT INTO purchase_order_items(order_id,product_id,quantity,unit_cost)
  VALUES(result_id,(line->>'product_id')::integer,(line->>'quantity')::integer,(line->>'unit_cost')::numeric);
 END LOOP;
 RETURN result_id;
END $$;
CREATE OR REPLACE FUNCTION receive_purchase_order(p_order integer,p_actor integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
DECLARE po purchase_orders%ROWTYPE; item record; total integer:=0;
BEGIN
 PERFORM check_actor(p_actor);
 SELECT * INTO po FROM purchase_orders WHERE order_id=p_order FOR UPDATE;
 IF NOT FOUND OR po.status<>'PLACED' THEN RAISE EXCEPTION 'Only a placed order can be received'; END IF;
 IF NOT EXISTS(SELECT 1 FROM purchase_order_items WHERE order_id=p_order) THEN RAISE EXCEPTION 'Order has no items'; END IF;
 FOR item IN SELECT * FROM purchase_order_items WHERE order_id=p_order ORDER BY product_id LOOP
  INSERT INTO inventory(product_id,warehouse_id,quantity,reorder_level) VALUES(item.product_id,po.warehouse_id,0,10) ON CONFLICT DO NOTHING;
  PERFORM record_movement(item.product_id,NULL,po.warehouse_id,'RECEIPT',item.quantity,p_actor,'Receipt for PO-'||p_order);
  total:=total+item.quantity;
 END LOOP;
 UPDATE purchase_orders SET status='RECEIVED' WHERE order_id=p_order;
 RETURN total;
END $$;
CREATE OR REPLACE FUNCTION cancel_purchase_order(p_order integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
BEGIN
 UPDATE purchase_orders SET status='CANCELLED' WHERE order_id=p_order AND status IN ('DRAFT','PLACED');
 IF NOT FOUND THEN RAISE EXCEPTION 'Only draft or placed orders can be cancelled'; END IF;
END $$;
CREATE OR REPLACE FUNCTION initialize_inventory() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
 INSERT INTO inventory(product_id,warehouse_id,quantity,reorder_level)
 SELECT p.product_id,w.warehouse_id,0,10 FROM products p CROSS JOIN warehouses w ON CONFLICT DO NOTHING;
$$;
CREATE OR REPLACE FUNCTION remove_product(p_id integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
BEGIN
 PERFORM 1 FROM products WHERE product_id=p_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM stock_movements WHERE product_id=p_id)
 OR EXISTS(SELECT 1 FROM purchase_order_items WHERE product_id=p_id)
 OR EXISTS(SELECT 1 FROM inventory WHERE product_id=p_id AND quantity<>0)
 THEN RAISE EXCEPTION 'A product with stock or transaction history cannot be deleted'; END IF;
 DELETE FROM low_stock_alerts WHERE product_id=p_id;
 DELETE FROM inventory WHERE product_id=p_id;
 DELETE FROM products WHERE product_id=p_id;
END $$;
CREATE OR REPLACE FUNCTION remove_warehouse(p_id integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
BEGIN
 PERFORM 1 FROM warehouses WHERE warehouse_id=p_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM stock_movements WHERE source_warehouse_id=p_id OR destination_warehouse_id=p_id)
 OR EXISTS(SELECT 1 FROM purchase_orders WHERE warehouse_id=p_id)
 OR EXISTS(SELECT 1 FROM inventory WHERE warehouse_id=p_id AND quantity<>0)
 THEN RAISE EXCEPTION 'A warehouse with stock or transaction history cannot be deleted'; END IF;
 DELETE FROM low_stock_alerts WHERE warehouse_id=p_id;
 DELETE FROM inventory WHERE warehouse_id=p_id;
 DELETE FROM warehouses WHERE warehouse_id=p_id;
END $$;
CREATE OR REPLACE FUNCTION create_app_user(p_name text,p_email text,p_role text,p_hash text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=smartvault,pg_temp AS $$
DECLARE result_id integer;
BEGIN
 IF p_hash NOT LIKE 'scrypt$%' THEN RAISE EXCEPTION 'A scrypt password hash is required'; END IF;
 INSERT INTO app_users(full_name,email,role,password_hash) VALUES(p_name,lower(p_email),p_role,p_hash) RETURNING user_id INTO result_id;
 RETURN result_id;
END $$;

CREATE OR REPLACE VIEW v_pattern_features AS
WITH events AS (
 SELECT product_id,source_warehouse_id AS warehouse_id,movement_type,quantity FROM stock_movements WHERE source_warehouse_id IS NOT NULL
 UNION ALL SELECT product_id,destination_warehouse_id,movement_type,quantity FROM stock_movements WHERE destination_warehouse_id IS NOT NULL
), activity AS (
 SELECT product_id,warehouse_id,count(*) AS movement_count,
 COALESCE(sum(quantity) FILTER(WHERE movement_type='RECEIPT'),0) AS received,
 COALESCE(sum(quantity) FILTER(WHERE movement_type='ISSUE'),0) AS issued,
 COALESCE(sum(quantity) FILTER(WHERE movement_type='TRANSFER'),0) AS transferred
 FROM events GROUP BY product_id,warehouse_id
)
SELECT i.product_id,i.warehouse_id,p.product_name,w.warehouse_name,i.quantity,i.reorder_level,
 COALESCE(a.movement_count,0) AS movement_count,COALESCE(a.received,0) AS received,
 COALESCE(a.issued,0) AS issued,COALESCE(a.transferred,0) AS transferred
FROM inventory i JOIN products p USING(product_id) JOIN warehouses w USING(warehouse_id)
LEFT JOIN activity a USING(product_id,warehouse_id);

REVOKE ALL ON ALL TABLES IN SCHEMA smartvault FROM smartvault_admin,smartvault_staff,smartvault_auth;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA smartvault FROM smartvault_admin,smartvault_staff,smartvault_auth;
GRANT SELECT ON categories,suppliers,warehouses,products,inventory,purchase_orders,purchase_order_items,
 stock_movements,low_stock_alerts,anomaly_logs,v_inventory_report,v_purchase_order_totals,v_pattern_features
 TO smartvault_admin,smartvault_staff;
GRANT SELECT(user_id,full_name,email,role) ON app_users TO smartvault_admin,smartvault_staff;
GRANT SELECT(user_id,email) ON app_users TO smartvault_auth;
GRANT INSERT,UPDATE,DELETE ON categories,suppliers,warehouses,products TO smartvault_admin;
GRANT USAGE,SELECT ON ALL SEQUENCES IN SCHEMA smartvault TO smartvault_admin;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA smartvault FROM PUBLIC;
GRANT EXECUTE ON FUNCTION login_record(text),get_session_user(integer),create_app_user(text,text,text,text) TO smartvault_auth;
GRANT EXECUTE ON FUNCTION record_movement(integer,integer,integer,text,integer,integer,text),
 create_purchase_order(integer,integer,integer,jsonb) TO smartvault_admin,smartvault_staff;
GRANT EXECUTE ON FUNCTION receive_purchase_order(integer,integer),cancel_purchase_order(integer),initialize_inventory(),
 remove_product(integer),remove_warehouse(integer),create_app_user(text,text,text,text) TO smartvault_admin;

INSERT INTO categories(category_name,parent_category_id) VALUES('Computer peripherals',1)
ON CONFLICT(category_name) DO UPDATE SET parent_category_id=EXCLUDED.parent_category_id;
UPDATE products SET category_id=(SELECT category_id FROM categories WHERE category_name='Computer peripherals')
WHERE sku IN ('EL-001','EL-002');
COMMIT;

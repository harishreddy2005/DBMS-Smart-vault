--
-- PostgreSQL database dump
--

-- Dumped from database version 17.2
-- Dumped by pg_dump version 17.2

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: smartvault; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA smartvault;


--
-- Name: apply_stock_movement(); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.apply_stock_movement() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
BEGIN
 PERFORM 1 FROM inventory
 WHERE product_id=NEW.product_id
 AND warehouse_id IN (NEW.source_warehouse_id, NEW.destination_warehouse_id)
 ORDER BY warehouse_id FOR UPDATE;
 IF NEW.source_warehouse_id IS NOT NULL THEN
  UPDATE inventory SET quantity=quantity-NEW.quantity
  WHERE product_id=NEW.product_id AND warehouse_id=NEW.source_warehouse_id
    AND quantity >= NEW.quantity;
  IF NOT FOUND THEN
   RAISE EXCEPTION 'Source inventory missing or insufficient stock';
  END IF;
 END IF;
 IF NEW.destination_warehouse_id IS NOT NULL THEN
  UPDATE inventory SET quantity=quantity+NEW.quantity
  WHERE product_id=NEW.product_id AND warehouse_id=NEW.destination_warehouse_id;
  IF NOT FOUND THEN
   RAISE EXCEPTION 'Destination inventory row does not exist';
  END IF;
 END IF;
 RETURN NEW;
END;
$$;


--
-- Name: cancel_purchase_order(integer); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.cancel_purchase_order(p_order integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
BEGIN
 UPDATE purchase_orders SET status='CANCELLED' WHERE order_id=p_order AND status IN ('DRAFT','PLACED');
 IF NOT FOUND THEN RAISE EXCEPTION 'Only draft or placed orders can be cancelled'; END IF;
END $$;


--
-- Name: check_actor(integer); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.check_actor(p_actor integer) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
DECLARE actor_role text;
BEGIN
 SELECT role INTO actor_role FROM app_users WHERE user_id=p_actor;
 IF actor_role IS NULL THEN RAISE EXCEPTION 'User does not exist'; END IF;
 IF (session_user='smartvault_staff' AND actor_role<>'STAFF') OR
    (session_user='smartvault_admin' AND actor_role<>'ADMIN') THEN
  RAISE EXCEPTION 'Actor role does not match the database connection role';
 END IF;
END $$;


--
-- Name: create_app_user(text, text, text, text); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.create_app_user(p_name text, p_email text, p_role text, p_hash text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $_$
DECLARE result_id integer;
BEGIN
 IF p_hash NOT LIKE 'scrypt$%' THEN RAISE EXCEPTION 'A scrypt password hash is required'; END IF;
 INSERT INTO app_users(full_name,email,role,password_hash) VALUES(p_name,lower(p_email),p_role,p_hash) RETURNING user_id INTO result_id;
 RETURN result_id;
END $_$;


--
-- Name: create_purchase_order(integer, integer, integer, jsonb); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.create_purchase_order(p_supplier integer, p_warehouse integer, p_actor integer, p_items jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
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


--
-- Name: detect_large_issue(); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.detect_large_issue() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
BEGIN
 IF NEW.movement_type='ISSUE' AND NEW.quantity >= 50 THEN
  INSERT INTO anomaly_logs(movement_id, rule_name, reason, detected_at)
  VALUES (NEW.movement_id, 'LARGE_ISSUE',
   'Single issue of at least 50 units; review required, not proof of fraud.',
   NEW.occurred_at);
 END IF;
 RETURN NEW;
END;
$$;


--
-- Name: get_session_user(integer); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.get_session_user(p_id integer) RETURNS TABLE(user_id integer, full_name character varying, email character varying, role character varying)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
 SELECT u.user_id,u.full_name,u.email,u.role FROM app_users u WHERE u.user_id=p_id;
$$;


--
-- Name: initialize_inventory(); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.initialize_inventory() RETURNS void
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
 INSERT INTO inventory(product_id,warehouse_id,quantity,reorder_level)
 SELECT p.product_id,w.warehouse_id,0,10 FROM products p CROSS JOIN warehouses w ON CONFLICT DO NOTHING;
$$;


--
-- Name: login_record(text); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.login_record(p_email text) RETURNS TABLE(user_id integer, full_name character varying, email character varying, role character varying, password_hash text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
 SELECT u.user_id,u.full_name,u.email,u.role,u.password_hash FROM app_users u WHERE lower(u.email)=lower(p_email);
$$;


--
-- Name: prevent_category_cycle(); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.prevent_category_cycle() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
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


--
-- Name: receive_purchase_order(integer, integer); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.receive_purchase_order(p_order integer, p_actor integer) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
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


--
-- Name: record_movement(integer, integer, integer, text, integer, integer, text); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.record_movement(p_product integer, p_source integer, p_destination integer, p_type text, p_quantity integer, p_actor integer, p_note text DEFAULT ''::text) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
DECLARE result_id integer;
BEGIN
 PERFORM check_actor(p_actor);
 INSERT INTO stock_movements(product_id,source_warehouse_id,destination_warehouse_id,movement_type,quantity,performed_by,note)
 VALUES(p_product,p_source,p_destination,p_type,p_quantity,p_actor,left(p_note,200))
 RETURNING movement_id INTO result_id;
 RETURN result_id;
END $$;


--
-- Name: reject_movement_edit(); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.reject_movement_edit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
 RAISE EXCEPTION 'Posted stock movements cannot be updated or deleted';
END;
$$;


--
-- Name: remove_product(integer); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.remove_product(p_id integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
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


--
-- Name: remove_warehouse(integer); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.remove_warehouse(p_id integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
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


--
-- Name: sync_low_stock_alert(); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.sync_low_stock_alert() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
BEGIN
 IF NEW.quantity < NEW.reorder_level THEN
  INSERT INTO low_stock_alerts(product_id, warehouse_id, observed_quantity, threshold, status)
  VALUES (NEW.product_id, NEW.warehouse_id, NEW.quantity, NEW.reorder_level, 'OPEN')
  ON CONFLICT (product_id, warehouse_id) DO UPDATE SET
   observed_quantity=EXCLUDED.observed_quantity, threshold=EXCLUDED.threshold,
   raised_at=CASE WHEN low_stock_alerts.status='RESOLVED' THEN CURRENT_TIMESTAMP ELSE low_stock_alerts.raised_at END,
   status='OPEN', resolved_at=NULL;
 ELSE
  UPDATE low_stock_alerts SET observed_quantity=NEW.quantity,
   threshold=NEW.reorder_level, status='RESOLVED', resolved_at=CURRENT_TIMESTAMP
  WHERE product_id=NEW.product_id AND warehouse_id=NEW.warehouse_id;
 END IF;
 RETURN NEW;
END;
$$;


--
-- Name: transfer_stock(integer, integer, integer, integer, integer); Type: FUNCTION; Schema: smartvault; Owner: -
--

CREATE FUNCTION smartvault.transfer_stock(p_product integer, p_source integer, p_destination integer, p_quantity integer, p_user integer) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'smartvault', 'pg_temp'
    AS $$
DECLARE result_id integer;
BEGIN
 INSERT INTO stock_movements(product_id, source_warehouse_id,
  destination_warehouse_id, movement_type, quantity, performed_by, note)
 VALUES (p_product,p_source,p_destination,'TRANSFER',p_quantity,p_user,'Warehouse transfer')
 RETURNING movement_id INTO result_id;
 RETURN result_id;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: anomaly_logs; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.anomaly_logs (
    anomaly_id integer NOT NULL,
    movement_id integer NOT NULL,
    rule_name character varying(60) NOT NULL,
    reason character varying(200) NOT NULL,
    detected_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: anomaly_logs_anomaly_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.anomaly_logs ALTER COLUMN anomaly_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.anomaly_logs_anomaly_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: app_users; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.app_users (
    user_id integer NOT NULL,
    full_name character varying(100) NOT NULL,
    email character varying(160) NOT NULL,
    role character varying(10) NOT NULL,
    password_hash text,
    CONSTRAINT app_users_role_check CHECK (((role)::text = ANY ((ARRAY['ADMIN'::character varying, 'STAFF'::character varying])::text[])))
);


--
-- Name: app_users_user_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.app_users ALTER COLUMN user_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.app_users_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: categories; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.categories (
    category_id integer NOT NULL,
    category_name character varying(80) NOT NULL,
    parent_category_id integer
);


--
-- Name: categories_category_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.categories ALTER COLUMN category_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.categories_category_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: inventory; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.inventory (
    product_id integer NOT NULL,
    warehouse_id integer NOT NULL,
    quantity integer DEFAULT 0 NOT NULL,
    reorder_level integer DEFAULT 10 NOT NULL,
    CONSTRAINT inventory_quantity_check CHECK ((quantity >= 0)),
    CONSTRAINT inventory_reorder_level_check CHECK ((reorder_level >= 0))
);


--
-- Name: low_stock_alerts; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.low_stock_alerts (
    alert_id integer NOT NULL,
    product_id integer NOT NULL,
    warehouse_id integer NOT NULL,
    observed_quantity integer NOT NULL,
    threshold integer NOT NULL,
    status character varying(8) NOT NULL,
    raised_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    resolved_at timestamp with time zone,
    CONSTRAINT low_stock_alerts_check CHECK (((((status)::text = 'OPEN'::text) AND (resolved_at IS NULL)) OR (((status)::text = 'RESOLVED'::text) AND (resolved_at IS NOT NULL)))),
    CONSTRAINT low_stock_alerts_observed_quantity_check CHECK ((observed_quantity >= 0)),
    CONSTRAINT low_stock_alerts_status_check CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'RESOLVED'::character varying])::text[]))),
    CONSTRAINT low_stock_alerts_threshold_check CHECK ((threshold >= 0))
);


--
-- Name: low_stock_alerts_alert_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.low_stock_alerts ALTER COLUMN alert_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.low_stock_alerts_alert_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: products; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.products (
    product_id integer NOT NULL,
    sku character varying(30) NOT NULL,
    product_name character varying(100) NOT NULL,
    category_id integer NOT NULL,
    preferred_supplier_id integer NOT NULL,
    unit_price numeric(12,2) NOT NULL,
    CONSTRAINT products_unit_price_check CHECK ((unit_price >= (0)::numeric))
);


--
-- Name: products_product_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.products ALTER COLUMN product_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.products_product_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: purchase_order_items; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.purchase_order_items (
    order_id integer NOT NULL,
    product_id integer NOT NULL,
    quantity integer NOT NULL,
    unit_cost numeric(12,2) NOT NULL,
    CONSTRAINT purchase_order_items_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT purchase_order_items_unit_cost_check CHECK ((unit_cost >= (0)::numeric))
);


--
-- Name: purchase_orders; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.purchase_orders (
    order_id integer NOT NULL,
    supplier_id integer NOT NULL,
    warehouse_id integer NOT NULL,
    created_by integer NOT NULL,
    order_date date NOT NULL,
    status character varying(12) NOT NULL,
    CONSTRAINT purchase_orders_status_check CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'PLACED'::character varying, 'RECEIVED'::character varying, 'CANCELLED'::character varying])::text[])))
);


--
-- Name: purchase_orders_order_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.purchase_orders ALTER COLUMN order_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.purchase_orders_order_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: stock_movements; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.stock_movements (
    movement_id integer NOT NULL,
    product_id integer NOT NULL,
    source_warehouse_id integer,
    destination_warehouse_id integer,
    movement_type character varying(10) NOT NULL,
    quantity integer NOT NULL,
    performed_by integer NOT NULL,
    occurred_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    note character varying(200),
    CONSTRAINT stock_movements_check CHECK (((((movement_type)::text = 'RECEIPT'::text) AND (source_warehouse_id IS NULL) AND (destination_warehouse_id IS NOT NULL)) OR (((movement_type)::text = 'ISSUE'::text) AND (source_warehouse_id IS NOT NULL) AND (destination_warehouse_id IS NULL)) OR (((movement_type)::text = 'TRANSFER'::text) AND (source_warehouse_id IS NOT NULL) AND (destination_warehouse_id IS NOT NULL) AND (source_warehouse_id <> destination_warehouse_id)))),
    CONSTRAINT stock_movements_movement_type_check CHECK (((movement_type)::text = ANY ((ARRAY['RECEIPT'::character varying, 'ISSUE'::character varying, 'TRANSFER'::character varying])::text[]))),
    CONSTRAINT stock_movements_quantity_check CHECK ((quantity > 0))
);


--
-- Name: stock_movements_movement_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.stock_movements ALTER COLUMN movement_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.stock_movements_movement_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: suppliers; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.suppliers (
    supplier_id integer NOT NULL,
    supplier_name character varying(100) NOT NULL,
    email character varying(160) NOT NULL,
    phone character varying(20) NOT NULL
);


--
-- Name: suppliers_supplier_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.suppliers ALTER COLUMN supplier_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.suppliers_supplier_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: warehouses; Type: TABLE; Schema: smartvault; Owner: -
--

CREATE TABLE smartvault.warehouses (
    warehouse_id integer NOT NULL,
    warehouse_name character varying(100) NOT NULL,
    city character varying(80) NOT NULL
);


--
-- Name: v_inventory_report; Type: VIEW; Schema: smartvault; Owner: -
--

CREATE VIEW smartvault.v_inventory_report AS
 SELECT p.product_id,
    p.sku,
    p.product_name,
    c.category_name,
    w.warehouse_id,
    w.warehouse_name,
    w.city,
    i.quantity,
    i.reorder_level,
    p.unit_price,
    ((i.quantity)::numeric * p.unit_price) AS stock_value,
        CASE
            WHEN (i.quantity = 0) THEN 'OUT OF STOCK'::text
            WHEN (i.quantity < i.reorder_level) THEN 'LOW STOCK'::text
            ELSE 'AVAILABLE'::text
        END AS availability
   FROM (((smartvault.inventory i
     JOIN smartvault.products p USING (product_id))
     JOIN smartvault.categories c USING (category_id))
     JOIN smartvault.warehouses w USING (warehouse_id));


--
-- Name: v_pattern_features; Type: VIEW; Schema: smartvault; Owner: -
--

CREATE VIEW smartvault.v_pattern_features AS
 WITH events AS (
         SELECT stock_movements.product_id,
            stock_movements.source_warehouse_id AS warehouse_id,
            stock_movements.movement_type,
            stock_movements.quantity
           FROM smartvault.stock_movements
          WHERE (stock_movements.source_warehouse_id IS NOT NULL)
        UNION ALL
         SELECT stock_movements.product_id,
            stock_movements.destination_warehouse_id,
            stock_movements.movement_type,
            stock_movements.quantity
           FROM smartvault.stock_movements
          WHERE (stock_movements.destination_warehouse_id IS NOT NULL)
        ), activity AS (
         SELECT events.product_id,
            events.warehouse_id,
            count(*) AS movement_count,
            COALESCE(sum(events.quantity) FILTER (WHERE ((events.movement_type)::text = 'RECEIPT'::text)), (0)::bigint) AS received,
            COALESCE(sum(events.quantity) FILTER (WHERE ((events.movement_type)::text = 'ISSUE'::text)), (0)::bigint) AS issued,
            COALESCE(sum(events.quantity) FILTER (WHERE ((events.movement_type)::text = 'TRANSFER'::text)), (0)::bigint) AS transferred
           FROM events
          GROUP BY events.product_id, events.warehouse_id
        )
 SELECT i.product_id,
    i.warehouse_id,
    p.product_name,
    w.warehouse_name,
    i.quantity,
    i.reorder_level,
    COALESCE(a.movement_count, (0)::bigint) AS movement_count,
    COALESCE(a.received, (0)::bigint) AS received,
    COALESCE(a.issued, (0)::bigint) AS issued,
    COALESCE(a.transferred, (0)::bigint) AS transferred
   FROM (((smartvault.inventory i
     JOIN smartvault.products p USING (product_id))
     JOIN smartvault.warehouses w USING (warehouse_id))
     LEFT JOIN activity a USING (product_id, warehouse_id));


--
-- Name: v_purchase_order_totals; Type: VIEW; Schema: smartvault; Owner: -
--

CREATE VIEW smartvault.v_purchase_order_totals AS
 SELECT po.order_id,
    s.supplier_name,
    w.warehouse_name,
    po.order_date,
    po.status,
    COALESCE(sum(((poi.quantity)::numeric * poi.unit_cost)), (0)::numeric) AS order_total
   FROM (((smartvault.purchase_orders po
     JOIN smartvault.suppliers s USING (supplier_id))
     JOIN smartvault.warehouses w USING (warehouse_id))
     LEFT JOIN smartvault.purchase_order_items poi USING (order_id))
  GROUP BY po.order_id, s.supplier_name, w.warehouse_name, po.order_date, po.status;


--
-- Name: warehouses_warehouse_id_seq; Type: SEQUENCE; Schema: smartvault; Owner: -
--

ALTER TABLE smartvault.warehouses ALTER COLUMN warehouse_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME smartvault.warehouses_warehouse_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: anomaly_logs anomaly_logs_movement_id_key; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.anomaly_logs
    ADD CONSTRAINT anomaly_logs_movement_id_key UNIQUE (movement_id);


--
-- Name: anomaly_logs anomaly_logs_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.anomaly_logs
    ADD CONSTRAINT anomaly_logs_pkey PRIMARY KEY (anomaly_id);


--
-- Name: app_users app_users_email_key; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.app_users
    ADD CONSTRAINT app_users_email_key UNIQUE (email);


--
-- Name: app_users app_users_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.app_users
    ADD CONSTRAINT app_users_pkey PRIMARY KEY (user_id);


--
-- Name: categories categories_category_name_key; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.categories
    ADD CONSTRAINT categories_category_name_key UNIQUE (category_name);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (category_id);


--
-- Name: inventory inventory_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.inventory
    ADD CONSTRAINT inventory_pkey PRIMARY KEY (product_id, warehouse_id);


--
-- Name: low_stock_alerts low_stock_alerts_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.low_stock_alerts
    ADD CONSTRAINT low_stock_alerts_pkey PRIMARY KEY (alert_id);


--
-- Name: low_stock_alerts low_stock_alerts_product_id_warehouse_id_key; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.low_stock_alerts
    ADD CONSTRAINT low_stock_alerts_product_id_warehouse_id_key UNIQUE (product_id, warehouse_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_id);


--
-- Name: products products_sku_key; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.products
    ADD CONSTRAINT products_sku_key UNIQUE (sku);


--
-- Name: purchase_order_items purchase_order_items_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.purchase_order_items
    ADD CONSTRAINT purchase_order_items_pkey PRIMARY KEY (order_id, product_id);


--
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (order_id);


--
-- Name: stock_movements stock_movements_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.stock_movements
    ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (movement_id);


--
-- Name: suppliers suppliers_email_key; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.suppliers
    ADD CONSTRAINT suppliers_email_key UNIQUE (email);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (supplier_id);


--
-- Name: warehouses warehouses_pkey; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.warehouses
    ADD CONSTRAINT warehouses_pkey PRIMARY KEY (warehouse_id);


--
-- Name: warehouses warehouses_warehouse_name_key; Type: CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.warehouses
    ADD CONSTRAINT warehouses_warehouse_name_key UNIQUE (warehouse_name);


--
-- Name: idx_inventory_warehouse; Type: INDEX; Schema: smartvault; Owner: -
--

CREATE INDEX idx_inventory_warehouse ON smartvault.inventory USING btree (warehouse_id);


--
-- Name: idx_movements_destination_time; Type: INDEX; Schema: smartvault; Owner: -
--

CREATE INDEX idx_movements_destination_time ON smartvault.stock_movements USING btree (destination_warehouse_id, occurred_at);


--
-- Name: idx_movements_product_time; Type: INDEX; Schema: smartvault; Owner: -
--

CREATE INDEX idx_movements_product_time ON smartvault.stock_movements USING btree (product_id, occurred_at);


--
-- Name: idx_movements_source_time; Type: INDEX; Schema: smartvault; Owner: -
--

CREATE INDEX idx_movements_source_time ON smartvault.stock_movements USING btree (source_warehouse_id, occurred_at);


--
-- Name: idx_order_items_product; Type: INDEX; Schema: smartvault; Owner: -
--

CREATE INDEX idx_order_items_product ON smartvault.purchase_order_items USING btree (product_id);


--
-- Name: idx_orders_supplier_date; Type: INDEX; Schema: smartvault; Owner: -
--

CREATE INDEX idx_orders_supplier_date ON smartvault.purchase_orders USING btree (supplier_id, order_date);


--
-- Name: idx_products_category; Type: INDEX; Schema: smartvault; Owner: -
--

CREATE INDEX idx_products_category ON smartvault.products USING btree (category_id);


--
-- Name: idx_products_supplier; Type: INDEX; Schema: smartvault; Owner: -
--

CREATE INDEX idx_products_supplier ON smartvault.products USING btree (preferred_supplier_id);


--
-- Name: categories category_cycle_guard; Type: TRIGGER; Schema: smartvault; Owner: -
--

CREATE TRIGGER category_cycle_guard BEFORE INSERT OR UPDATE OF parent_category_id ON smartvault.categories FOR EACH ROW EXECUTE FUNCTION smartvault.prevent_category_cycle();


--
-- Name: inventory inventory_low_stock; Type: TRIGGER; Schema: smartvault; Owner: -
--

CREATE TRIGGER inventory_low_stock AFTER INSERT OR UPDATE OF quantity, reorder_level ON smartvault.inventory FOR EACH ROW EXECUTE FUNCTION smartvault.sync_low_stock_alert();


--
-- Name: stock_movements movement_applies_stock; Type: TRIGGER; Schema: smartvault; Owner: -
--

CREATE TRIGGER movement_applies_stock BEFORE INSERT ON smartvault.stock_movements FOR EACH ROW EXECUTE FUNCTION smartvault.apply_stock_movement();


--
-- Name: stock_movements movement_detects_anomaly; Type: TRIGGER; Schema: smartvault; Owner: -
--

CREATE TRIGGER movement_detects_anomaly AFTER INSERT ON smartvault.stock_movements FOR EACH ROW EXECUTE FUNCTION smartvault.detect_large_issue();


--
-- Name: stock_movements movement_immutable; Type: TRIGGER; Schema: smartvault; Owner: -
--

CREATE TRIGGER movement_immutable BEFORE DELETE OR UPDATE ON smartvault.stock_movements FOR EACH ROW EXECUTE FUNCTION smartvault.reject_movement_edit();


--
-- Name: anomaly_logs anomaly_logs_movement_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.anomaly_logs
    ADD CONSTRAINT anomaly_logs_movement_id_fkey FOREIGN KEY (movement_id) REFERENCES smartvault.stock_movements(movement_id);


--
-- Name: categories categories_parent_category_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.categories
    ADD CONSTRAINT categories_parent_category_id_fkey FOREIGN KEY (parent_category_id) REFERENCES smartvault.categories(category_id);


--
-- Name: inventory inventory_product_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.inventory
    ADD CONSTRAINT inventory_product_id_fkey FOREIGN KEY (product_id) REFERENCES smartvault.products(product_id);


--
-- Name: inventory inventory_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.inventory
    ADD CONSTRAINT inventory_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES smartvault.warehouses(warehouse_id);


--
-- Name: low_stock_alerts low_stock_alerts_product_id_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.low_stock_alerts
    ADD CONSTRAINT low_stock_alerts_product_id_warehouse_id_fkey FOREIGN KEY (product_id, warehouse_id) REFERENCES smartvault.inventory(product_id, warehouse_id);


--
-- Name: products products_category_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES smartvault.categories(category_id);


--
-- Name: products products_preferred_supplier_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.products
    ADD CONSTRAINT products_preferred_supplier_id_fkey FOREIGN KEY (preferred_supplier_id) REFERENCES smartvault.suppliers(supplier_id);


--
-- Name: purchase_order_items purchase_order_items_order_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.purchase_order_items
    ADD CONSTRAINT purchase_order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES smartvault.purchase_orders(order_id);


--
-- Name: purchase_order_items purchase_order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.purchase_order_items
    ADD CONSTRAINT purchase_order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES smartvault.products(product_id);


--
-- Name: purchase_orders purchase_orders_created_by_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.purchase_orders
    ADD CONSTRAINT purchase_orders_created_by_fkey FOREIGN KEY (created_by) REFERENCES smartvault.app_users(user_id);


--
-- Name: purchase_orders purchase_orders_supplier_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.purchase_orders
    ADD CONSTRAINT purchase_orders_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES smartvault.suppliers(supplier_id);


--
-- Name: purchase_orders purchase_orders_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.purchase_orders
    ADD CONSTRAINT purchase_orders_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES smartvault.warehouses(warehouse_id);


--
-- Name: stock_movements stock_movements_destination_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.stock_movements
    ADD CONSTRAINT stock_movements_destination_warehouse_id_fkey FOREIGN KEY (destination_warehouse_id) REFERENCES smartvault.warehouses(warehouse_id);


--
-- Name: stock_movements stock_movements_performed_by_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.stock_movements
    ADD CONSTRAINT stock_movements_performed_by_fkey FOREIGN KEY (performed_by) REFERENCES smartvault.app_users(user_id);


--
-- Name: stock_movements stock_movements_product_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.stock_movements
    ADD CONSTRAINT stock_movements_product_id_fkey FOREIGN KEY (product_id) REFERENCES smartvault.products(product_id);


--
-- Name: stock_movements stock_movements_source_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: smartvault; Owner: -
--

ALTER TABLE ONLY smartvault.stock_movements
    ADD CONSTRAINT stock_movements_source_warehouse_id_fkey FOREIGN KEY (source_warehouse_id) REFERENCES smartvault.warehouses(warehouse_id);


--
-- Name: SCHEMA smartvault; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA smartvault TO smartvault_admin;
GRANT USAGE ON SCHEMA smartvault TO smartvault_staff;
GRANT USAGE ON SCHEMA smartvault TO smartvault_auth;


--
-- Name: FUNCTION apply_stock_movement(); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.apply_stock_movement() FROM PUBLIC;


--
-- Name: FUNCTION cancel_purchase_order(p_order integer); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.cancel_purchase_order(p_order integer) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.cancel_purchase_order(p_order integer) TO smartvault_admin;


--
-- Name: FUNCTION check_actor(p_actor integer); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.check_actor(p_actor integer) FROM PUBLIC;


--
-- Name: FUNCTION create_app_user(p_name text, p_email text, p_role text, p_hash text); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.create_app_user(p_name text, p_email text, p_role text, p_hash text) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.create_app_user(p_name text, p_email text, p_role text, p_hash text) TO smartvault_admin;


--
-- Name: FUNCTION create_purchase_order(p_supplier integer, p_warehouse integer, p_actor integer, p_items jsonb); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.create_purchase_order(p_supplier integer, p_warehouse integer, p_actor integer, p_items jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.create_purchase_order(p_supplier integer, p_warehouse integer, p_actor integer, p_items jsonb) TO smartvault_admin;
GRANT ALL ON FUNCTION smartvault.create_purchase_order(p_supplier integer, p_warehouse integer, p_actor integer, p_items jsonb) TO smartvault_staff;


--
-- Name: FUNCTION detect_large_issue(); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.detect_large_issue() FROM PUBLIC;


--
-- Name: FUNCTION get_session_user(p_id integer); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.get_session_user(p_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.get_session_user(p_id integer) TO smartvault_auth;


--
-- Name: FUNCTION initialize_inventory(); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.initialize_inventory() FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.initialize_inventory() TO smartvault_admin;


--
-- Name: FUNCTION login_record(p_email text); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.login_record(p_email text) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.login_record(p_email text) TO smartvault_auth;


--
-- Name: FUNCTION prevent_category_cycle(); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.prevent_category_cycle() FROM PUBLIC;


--
-- Name: FUNCTION receive_purchase_order(p_order integer, p_actor integer); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.receive_purchase_order(p_order integer, p_actor integer) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.receive_purchase_order(p_order integer, p_actor integer) TO smartvault_admin;


--
-- Name: FUNCTION record_movement(p_product integer, p_source integer, p_destination integer, p_type text, p_quantity integer, p_actor integer, p_note text); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.record_movement(p_product integer, p_source integer, p_destination integer, p_type text, p_quantity integer, p_actor integer, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.record_movement(p_product integer, p_source integer, p_destination integer, p_type text, p_quantity integer, p_actor integer, p_note text) TO smartvault_admin;
GRANT ALL ON FUNCTION smartvault.record_movement(p_product integer, p_source integer, p_destination integer, p_type text, p_quantity integer, p_actor integer, p_note text) TO smartvault_staff;


--
-- Name: FUNCTION reject_movement_edit(); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.reject_movement_edit() FROM PUBLIC;


--
-- Name: FUNCTION remove_product(p_id integer); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.remove_product(p_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.remove_product(p_id integer) TO smartvault_admin;


--
-- Name: FUNCTION remove_warehouse(p_id integer); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.remove_warehouse(p_id integer) FROM PUBLIC;
GRANT ALL ON FUNCTION smartvault.remove_warehouse(p_id integer) TO smartvault_admin;


--
-- Name: FUNCTION sync_low_stock_alert(); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.sync_low_stock_alert() FROM PUBLIC;


--
-- Name: FUNCTION transfer_stock(p_product integer, p_source integer, p_destination integer, p_quantity integer, p_user integer); Type: ACL; Schema: smartvault; Owner: -
--

REVOKE ALL ON FUNCTION smartvault.transfer_stock(p_product integer, p_source integer, p_destination integer, p_quantity integer, p_user integer) FROM PUBLIC;


--
-- Name: TABLE anomaly_logs; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.anomaly_logs TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.anomaly_logs TO smartvault_staff;


--
-- Name: SEQUENCE anomaly_logs_anomaly_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.anomaly_logs_anomaly_id_seq TO smartvault_admin;


--
-- Name: COLUMN app_users.user_id; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT(user_id) ON TABLE smartvault.app_users TO smartvault_admin;
GRANT SELECT(user_id) ON TABLE smartvault.app_users TO smartvault_staff;


--
-- Name: COLUMN app_users.full_name; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT(full_name) ON TABLE smartvault.app_users TO smartvault_admin;
GRANT SELECT(full_name) ON TABLE smartvault.app_users TO smartvault_staff;


--
-- Name: COLUMN app_users.email; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT(email) ON TABLE smartvault.app_users TO smartvault_admin;
GRANT SELECT(email) ON TABLE smartvault.app_users TO smartvault_staff;


--
-- Name: COLUMN app_users.role; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT(role) ON TABLE smartvault.app_users TO smartvault_admin;
GRANT SELECT(role) ON TABLE smartvault.app_users TO smartvault_staff;


--
-- Name: SEQUENCE app_users_user_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.app_users_user_id_seq TO smartvault_admin;


--
-- Name: TABLE categories; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE smartvault.categories TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.categories TO smartvault_staff;


--
-- Name: SEQUENCE categories_category_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.categories_category_id_seq TO smartvault_admin;


--
-- Name: TABLE inventory; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.inventory TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.inventory TO smartvault_staff;


--
-- Name: TABLE low_stock_alerts; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.low_stock_alerts TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.low_stock_alerts TO smartvault_staff;


--
-- Name: SEQUENCE low_stock_alerts_alert_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.low_stock_alerts_alert_id_seq TO smartvault_admin;


--
-- Name: TABLE products; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE smartvault.products TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.products TO smartvault_staff;


--
-- Name: SEQUENCE products_product_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.products_product_id_seq TO smartvault_admin;


--
-- Name: TABLE purchase_order_items; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.purchase_order_items TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.purchase_order_items TO smartvault_staff;


--
-- Name: TABLE purchase_orders; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.purchase_orders TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.purchase_orders TO smartvault_staff;


--
-- Name: SEQUENCE purchase_orders_order_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.purchase_orders_order_id_seq TO smartvault_admin;


--
-- Name: TABLE stock_movements; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.stock_movements TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.stock_movements TO smartvault_staff;


--
-- Name: SEQUENCE stock_movements_movement_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.stock_movements_movement_id_seq TO smartvault_admin;


--
-- Name: TABLE suppliers; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE smartvault.suppliers TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.suppliers TO smartvault_staff;


--
-- Name: SEQUENCE suppliers_supplier_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.suppliers_supplier_id_seq TO smartvault_admin;


--
-- Name: TABLE warehouses; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE smartvault.warehouses TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.warehouses TO smartvault_staff;


--
-- Name: TABLE v_inventory_report; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.v_inventory_report TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.v_inventory_report TO smartvault_staff;


--
-- Name: TABLE v_pattern_features; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.v_pattern_features TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.v_pattern_features TO smartvault_staff;


--
-- Name: TABLE v_purchase_order_totals; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT ON TABLE smartvault.v_purchase_order_totals TO smartvault_admin;
GRANT SELECT ON TABLE smartvault.v_purchase_order_totals TO smartvault_staff;


--
-- Name: SEQUENCE warehouses_warehouse_id_seq; Type: ACL; Schema: smartvault; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE smartvault.warehouses_warehouse_id_seq TO smartvault_admin;


--
-- PostgreSQL database dump complete
--

